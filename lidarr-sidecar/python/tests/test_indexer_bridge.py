#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

import base64
import json
import sqlite3
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from contextlib import closing
from datetime import date, timedelta
from http import HTTPStatus
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from deemix_downloader.indexer_background import SearchWarming
from deemix_downloader.indexer_bridge import BridgeStore, IndexerBridge


class IndexerBridgeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.work_path = Path(self.temporary.name)
        self.downloads = []
        self.bridge = self.make_bridge()

    def make_bridge(self, limit=1, download=None):
        def fake_search(**_query):
            return [self.release()]

        def fake_download(release, completed):
            self.downloads.append(release)
            completed()
            return True

        return IndexerBridge(
            public_url="http://127.0.0.1:9797",
            api_key="x" * 32,
            client_username="sidecar",
            client_password="p" * 16,
            work_path=self.work_path,
            import_path=self.work_path / "import",
            download_limit=limit,
            search=fake_search,
            download=download or fake_download,
            worker_interval=0.01,
        )

    def test_client_disconnect_during_response_is_handled(self):
        handler = object.__new__(self.bridge.handler())
        handler.send_response = Mock()
        handler.send_header = Mock()
        handler.end_headers = Mock()
        handler.wfile = Mock()
        handler.wfile.write.side_effect = BrokenPipeError

        handler._respond(HTTPStatus.OK, b"response", "application/rss+xml")

        handler.send_response.assert_called_once_with(HTTPStatus.OK)

    def test_warming_search_returns_a_specific_retry_message(self):
        self.bridge.search_callback = Mock(
            side_effect=SearchWarming("Search is warming in the background; retry later")
        )
        server = ThreadingHTTPServer(("127.0.0.1", 0), self.bridge.handler())
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        self.addCleanup(lambda: (server.shutdown(), thread.join(), server.server_close()))
        url = f"http://127.0.0.1:{server.server_port}/api?t=search&q=artist&apikey=" + ("x" * 32)
        with self.assertRaises(urllib.error.HTTPError) as response:
            urllib.request.urlopen(url, timeout=3)  # noqa: S310 - loopback-only test server.
        self.assertEqual(response.exception.code, 503)
        body = response.exception.read()
        response.exception.close()
        self.assertIn(b"Search is warming in the background; retry later", body)

    @staticmethod
    def release():
        return {
            "artist_id": "11",
            "artist_name": "Test Artist",
            "artist_foreign_id": "artist-mbid",
            "album_id": "22",
            "album_title": "Test Album",
            "report_title": "Test Artist - Test Album (2001)",
            "album_foreign_id": "group-mbid",
            "release_id": "33",
            "release_foreign_id": "release-mbid",
            "release_title": "Test Album",
            "deezer_album_id": "44",
            "deezer_title": "Test Album",
            "year": "2001",
            "track_count": 1,
        }

    def _submit(self, token, client_id="test-lidarr-download-id"):
        nzb = self.bridge._nzb(token)
        params = ["release.nzb", base64.b64encode(nzb).decode(), "Music"]
        params.extend([0, False, False, "", 0, "all", ["drone", client_id]])
        response, error = self.bridge._jsonrpc(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "append",
                "params": params,
            }
        )
        self.assertIsNone(error)
        return response

    def test_capabilities_and_search_responses_match_lidarr_newznab_contract(self):
        capabilities = ET.fromstring(self.bridge._capabilities())  # noqa: S314 - bridge-generated XML.
        music = capabilities.find("./searching/musicSearch")
        self.assertEqual(music.attrib, {"available": "yes", "supportedParams": "q,artist,album"})
        self.assertEqual(capabilities.find("./categories/category").attrib["id"], "3000")

        self.bridge._search_results({"t": ["music"], "artist": ["Test Artist"], "album": ["Test Album"]})
        first = ET.fromstring(self.bridge._rss([self.release()]))  # noqa: S314 - bridge-generated XML.
        second = ET.fromstring(self.bridge._rss([self.release()]))  # noqa: S314 - bridge-generated XML.
        first_item = first.find("./channel/item")
        second_item = second.find("./channel/item")
        self.assertIsNotNone(first_item)
        self.assertEqual(first_item.findtext("guid"), second_item.findtext("guid"))
        self.assertEqual(first_item.findtext("title"), "Test Artist - Test Album (2001)")
        self.assertEqual(first_item.find("enclosure").attrib["type"], "application/x-nzb")

        token = first_item.findtext("guid")
        nzb = ET.fromstring(self.bridge._nzb(token))  # noqa: S314 - bridge-generated XML.
        meta = nzb.find(".//{http://www.newzbin.com/DTD/2003/nzb}meta[@type='deemix-release-id']")
        self.assertEqual(meta.text, token)

    def test_jsonrpc_append_is_idempotent_and_preserves_forced_target_ids(self):
        release = self.bridge.store.register_release(self.release())
        first_id = self._submit(release["token"], "lidarr-grab-id")
        duplicate_id = self._submit(release["token"], "lidarr-grab-id")
        self.assertEqual(first_id, duplicate_id)
        item = self.bridge.store.jobs(("queued",))[0]
        self.assertEqual(item["nzb_id"], first_id)
        stored_release = self.bridge.store.get_release_for_job(item["id"])
        self.assertEqual(
            (stored_release["artist_id"], stored_release["album_id"], stored_release["release_id"]),
            ("11", "22", "33"),
        )
        self.assertEqual(self.bridge.store.client_ids(item["id"]), ("lidarr-grab-id",))

    def test_lidarr_history_delete_during_import_is_not_overwritten(self):
        def remove_after_import(_release, completed):
            completed()
            job = self.bridge.store.jobs(("downloaded",))[0]
            self.bridge.store.remove_job(job["nzb_id"])
            return True

        self.bridge = self.make_bridge(download=remove_after_import)
        release = self.bridge.store.register_release(self.release())
        self._submit(release["token"])
        self.bridge._run_job(self.bridge.store.next_job())

        job = self.bridge.store.jobs(("removed",))[0]
        self.assertEqual(job["status"], "removed")

    def test_duplicate_grabs_keep_each_lidarr_download_id_correlated(self):
        release = self.bridge.store.register_release(self.release())
        first_id = self._submit(release["token"], "lidarr-grab-one")
        duplicate_id = self._submit(release["token"], "lidarr-grab-two")
        self.assertEqual(first_id, duplicate_id)

        groups, error = self.bridge._jsonrpc({"jsonrpc": "2.0", "id": 2, "method": "listgroups", "params": []})
        self.assertIsNone(error)
        self.assertEqual(
            {group["Parameters"][0]["Value"] for group in groups},
            {"lidarr-grab-one", "lidarr-grab-two"},
        )

        self.bridge._run_job(self.bridge.store.next_job())
        self.assertEqual(
            self.downloads[0]["lidarr_download_ids"],
            ["lidarr-grab-one", "lidarr-grab-two"],
        )
        history, error = self.bridge._jsonrpc({"jsonrpc": "2.0", "id": 3, "method": "history", "params": []})
        self.assertIsNone(error)
        self.assertEqual(
            {item["Parameters"][0]["Value"] for item in history},
            {"lidarr-grab-one", "lidarr-grab-two"},
        )

    def test_completed_history_reports_an_existing_empty_destination(self):
        release = self.bridge.store.register_release(self.release())
        self._submit(release["token"])
        self.bridge._run_job(self.bridge.store.next_job())

        history, error = self.bridge._jsonrpc({"jsonrpc": "2.0", "id": 3, "method": "history", "params": []})
        self.assertIsNone(error)
        destination = Path(history[0]["DestDir"])
        self.assertTrue(destination.is_dir())
        self.assertEqual(list(destination.iterdir()), [])

        destination.rmdir()
        history, error = self.bridge._jsonrpc({"jsonrpc": "2.0", "id": 4, "method": "history", "params": []})
        self.assertIsNone(error)
        self.assertTrue(Path(history[0]["DestDir"]).is_dir())
        self.assertEqual(list(Path(history[0]["DestDir"]).iterdir()), [])

    def test_append_requires_a_lidarr_download_id(self):
        release = self.bridge.store.register_release(self.release())
        response, error = self.bridge._jsonrpc(
            {
                "jsonrpc": "2.0",
                "id": 2,
                "method": "append",
                "params": ["release.nzb", base64.b64encode(self.bridge._nzb(release["token"])).decode(), "Music"],
            }
        )
        self.assertIsNone(response)
        self.assertEqual(error["code"], -32602)
        self.assertEqual(self.bridge.store.jobs(("queued",)), [])

    def test_existing_job_database_gets_client_id_mapping_without_losing_jobs(self):
        database = self.work_path / "existing_jobs.sqlite3"
        with closing(sqlite3.connect(database)) as connection, connection:
            connection.executescript(
                """
                CREATE TABLE releases (token TEXT PRIMARY KEY, target TEXT NOT NULL UNIQUE, payload TEXT NOT NULL);
                CREATE TABLE jobs (
                    nzb_id INTEGER PRIMARY KEY AUTOINCREMENT,
                    id TEXT NOT NULL UNIQUE,
                    token TEXT NOT NULL,
                    attempt INTEGER NOT NULL,
                    status TEXT NOT NULL,
                    detail TEXT NOT NULL DEFAULT '',
                    created TEXT NOT NULL,
                    updated TEXT NOT NULL,
                    FOREIGN KEY(token) REFERENCES releases(token)
                );
                CREATE INDEX jobs_status_nzb_id ON jobs(status, nzb_id);
                CREATE INDEX jobs_token_nzb_id ON jobs(token, nzb_id);
                INSERT INTO releases VALUES ('token', '11:22:33', '{}');
                INSERT INTO jobs VALUES (1, 'old-job-id', 'token', 1, 'queued', '', 'now', 'now');
                """
            )

        store = BridgeStore(database)

        self.assertEqual(store.get_job("old-job-id")["nzb_id"], 1)
        self.assertEqual(store.client_ids("old-job-id"), ("old-job-id",))

    def test_quota_full_queues_grab_but_search_remains_available(self):
        self.bridge.quota.reserve("already-downloading")
        self.bridge.quota.complete("already-downloading")
        results = self.bridge._search_results({"t": ["music"], "artist": ["Test Artist"], "album": ["Test Album"]})
        self.assertEqual(len(results), 1)
        release = self.bridge.store.register_release(results[0])
        self._submit(release["token"])
        row = self.bridge.store.next_job()

        self.bridge._run_job(row)

        job = self.bridge.store.jobs(("waiting_quota",))[0]
        self.assertEqual(job["status"], "waiting_quota")
        self.assertEqual(self.downloads, [])
        groups, error = self.bridge._jsonrpc({"jsonrpc": "2.0", "id": 2, "method": "listgroups", "params": []})
        self.assertIsNone(error)
        self.assertEqual(groups[0]["ActiveDownloads"], 0)

        tomorrow = date.today() + timedelta(days=1)
        with patch.object(self.bridge.quota, "_today", return_value=tomorrow):
            self.bridge._run_job(job)
            self.assertEqual(self.bridge.quota.snapshot().completed, 1)
        self.assertEqual(self.bridge.store.jobs(("completed",))[0]["status"], "completed")

    def test_quota_is_counted_before_import_and_retained_when_import_fails(self):
        def failed_import(_release, completed):
            completed()
            return False

        self.bridge = self.make_bridge(download=failed_import)
        release = self.bridge.store.register_release(self.release())
        self._submit(release["token"])
        self.bridge._run_job(self.bridge.store.next_job())
        self.assertEqual(self.bridge.quota.snapshot().completed, 1)
        self.assertEqual(self.bridge.store.jobs(("failed",))[0]["detail"], "Download or strict manual import failed")
        history, error = self.bridge._jsonrpc({"jsonrpc": "2.0", "id": 3, "method": "history", "params": []})
        self.assertIsNone(error)
        self.assertEqual(history[0]["ParStatus"], "FAILURE")

    def test_history_redownload_retries_failed_job_with_a_new_quota_attempt(self):
        attempts = []

        def fail_then_succeed(_release, completed):
            attempts.append(None)
            if len(attempts) == 1:
                return False
            completed()
            return True

        self.bridge = self.make_bridge(download=fail_then_succeed)
        release = self.bridge.store.register_release(self.release())
        self._submit(release["token"])
        job = self.bridge.store.next_job()
        self.bridge._run_job(job)
        self.assertEqual(self.bridge.store.get_job(job["id"])["status"], "failed")

        response, error = self.bridge._jsonrpc(
            {
                "jsonrpc": "2.0",
                "id": 4,
                "method": "editqueue",
                "params": ["HistoryRedownload", "", "", job["nzb_id"]],
            }
        )

        self.assertIsNone(error)
        self.assertTrue(response)
        retry = self.bridge.store.next_job()
        self.assertEqual(retry["attempt"], 2)
        self.bridge._run_job(retry)
        completed = self.bridge.store.get_job(job["id"])
        self.assertEqual((completed["status"], completed["attempt"]), ("completed", 2))
        self.assertEqual(self.bridge.quota.snapshot().completed, 1)
        self.assertEqual(len(attempts), 2)

    def test_recovery_requeues_only_an_unfinished_reserved_download(self):
        release = self.bridge.store.register_release(self.release())
        self._submit(release["token"])
        job = self.bridge.store.next_job()
        job_id = job["id"]
        self.bridge.quota.reserve(f"{job_id}:{job['attempt']}")
        self.bridge.store.set_job(job_id, "downloading")

        restarted = self.make_bridge()

        self.assertEqual(restarted.store.get_job(job_id)["status"], "queued")
        restarted._run_job(restarted.store.next_job())
        self.assertEqual(restarted.store.get_job(job_id)["status"], "completed")
        self.assertEqual(restarted.quota.snapshot().completed, 1)

    def test_invalid_api_key_and_client_credentials_are_rejected(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), self.bridge.handler())
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        self.addCleanup(lambda: (server.shutdown(), thread.join(), server.server_close()))
        base_url = f"http://127.0.0.1:{server.server_port}"

        with self.assertRaises(urllib.error.HTTPError) as unauthorized:
            urllib.request.urlopen(base_url + "/api?t=caps", timeout=3)  # noqa: S310 - local test server.
        self.assertEqual(unauthorized.exception.code, 401)
        unauthorized.exception.close()

        request = urllib.request.Request(  # noqa: S310 - loopback-only test URL.
            base_url + "/api?t=caps&apikey=" + ("x" * 32),
            headers={"Authorization": "Basic " + base64.b64encode(b"wrong:wrong").decode()},
        )
        with urllib.request.urlopen(request, timeout=3) as response:  # noqa: S310 - local test server.
            self.assertEqual(response.status, 200)

        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "version", "params": []}).encode()
        request = urllib.request.Request(  # noqa: S310 - loopback-only test URL.
            base_url + "/jsonrpc",
            data=body,
            headers={"Content-Type": "application/json"},
        )
        with self.assertRaises(urllib.error.HTTPError) as client_unauthorized:
            urllib.request.urlopen(request, timeout=3)  # noqa: S310 - local test server.
        self.assertEqual(client_unauthorized.exception.code, 401)
        client_unauthorized.exception.close()


if __name__ == "__main__":
    unittest.main()
