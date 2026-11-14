#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

import json
import os
import sys
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from deemix_downloader import lidarr_api


class ManualImportReleaseTests(unittest.TestCase):
    def test_indexer_requests_do_not_wait_for_other_lidarr_commands(self):
        with (
            patch.dict(os.environ, {"SERVICE_INDEXER_ENABLED": "true"}),
            patch.object(lidarr_api, "_shared_arr_api_request") as request,
        ):
            lidarr_api.arr_api_request("POST", "command", "{}")
        request.assert_called_once_with("POST", "command", "{}", check_tasks=False)

    def test_search_request_can_run_during_command_poll_sleep(self):
        sleeping = threading.Event()
        resume = threading.Event()
        responses = iter([{"status": "started"}, {"status": "completed"}])
        state = {}

        def fake_request(_method, path, _payload=None):
            state["response"] = next(responses) if path.startswith("command/") else {"id": 42}

        def sleep(_seconds):
            sleeping.set()
            resume.wait(2)

        with (
            patch.object(lidarr_api, "arr_api_request", side_effect=fake_request),
            patch.object(lidarr_api, "get_state", side_effect=lambda _key: state["response"]),
            patch.object(lidarr_api.time, "sleep", side_effect=sleep),
        ):
            result = []
            searched = threading.Event()
            search_result = []
            worker = threading.Thread(target=lambda: result.append(lidarr_api._await_command(1, 5)))
            worker.start()

            def search():
                search_result.append(lidarr_api.request_response("GET", "parse?title=test"))
                searched.set()

            search_worker = threading.Thread(target=search)
            try:
                self.assertTrue(sleeping.wait(2))
                search_worker.start()
                self.assertTrue(searched.wait(0.5))
                self.assertEqual(search_result, [{"id": 42}])
            finally:
                resume.set()
                worker.join(2)
                if search_worker.ident is not None:
                    search_worker.join(2)
            self.assertEqual(result, [(True, "completed")])

    def _run(self, responses, *, strict=False):
        """Drive manual_import_release with a scripted sequence of API responses."""
        state = {"i": 0}

        def fake_get_state(key):
            if key != "arrApiResponse":
                return None
            value = responses[state["i"]]
            state["i"] += 1
            return value

        with (
            patch.object(lidarr_api, "arr_api_request") as mock_request,
            patch.object(lidarr_api, "get_state", side_effect=fake_get_state),
            patch.object(lidarr_api.time, "sleep"),
        ):
            result = lidarr_api.manual_import_release(
                import_path="/sidecar-import/Madonna - Album [mbid]",
                artist_id=628,
                album_id=22909,
                release_id=127617,
                strict=strict,
            )
        return result, mock_request

    def test_clean_reprocess_queues_manualimport_command(self):
        preview = [
            {"id": 1, "path": "/sidecar-import/a/01.flac", "quality": {"q": 1}},
            {"id": 2, "path": "/sidecar-import/a/02.flac", "quality": {"q": 1}},
        ]
        reprocessed = [
            {
                "id": 1,
                "path": "/sidecar-import/a/01.flac",
                "quality": {"q": 1},
                "rejections": [],
                "tracks": [{"id": 111}],
            },
            {
                "id": 2,
                "path": "/sidecar-import/a/02.flac",
                "quality": {"q": 1},
                "rejections": [],
                "tracks": [{"id": 222}],
            },
        ]
        responses = [
            preview,  # GET manualimport preview
            reprocessed,  # POST manualimport reprocess
            [],  # GET trackfile (before) -> 0 files
            {"id": 42, "status": "queued"},  # POST command
            {"status": "completed"},  # GET command/42
            [{"id": 1}, {"id": 2}],  # GET trackfile (after) -> 2 files
        ]

        (imported, rejections), mock_request = self._run(responses)

        self.assertTrue(imported)
        self.assertEqual(rejections, [])

        command_calls = [c for c in mock_request.call_args_list if c.args[:2] == ("POST", "command")]
        self.assertEqual(len(command_calls), 1)
        payload = json.loads(command_calls[0].args[2])
        self.assertEqual(payload["name"], "ManualImport")
        self.assertEqual(payload["importMode"], "move")
        self.assertTrue(payload["replaceExistingFiles"])
        self.assertEqual(len(payload["files"]), 2)
        self.assertEqual(payload["files"][0]["trackIds"], [111])
        self.assertEqual(payload["files"][1]["trackIds"], [222])
        self.assertEqual(payload["files"][0]["albumReleaseId"], 127617)

    def test_rejections_skip_command_and_report(self):
        preview = [{"id": 1, "path": "/sidecar-import/a/01.flac"}]
        reprocessed = [
            {
                "id": 1,
                "path": "/sidecar-import/a/01.flac",
                "rejections": [{"reason": "Not a sample"}],
                "tracks": [{"id": 111}],
            }
        ]
        responses = [preview, reprocessed]

        (imported, rejections), mock_request = self._run(responses)

        self.assertFalse(imported)
        self.assertEqual(rejections, ["/sidecar-import/a/01.flac: Not a sample"])
        self.assertFalse(any(c.args[:2] == ("POST", "command") for c in mock_request.call_args_list))

    def test_forced_album_score_rejection_uses_exact_manual_import_ids(self):
        preview = [{"id": 1, "path": "/sidecar-import/a/01.flac"}]
        reprocessed = [
            {
                "id": 1,
                "path": "/sidecar-import/a/01.flac",
                "artist": {"id": 628},
                "album": {"id": 22909},
                "albumReleaseId": 127617,
                "rejections": [{"reason": "Album match is not close enough: 75.1 % vs 80 % [country, tracks]"}],
                "tracks": [{"id": 111, "albumId": 22909}],
            }
        ]
        responses = [
            preview,
            reprocessed,
            [],  # GET trackfile (before) -> 0 files
            {"id": 42, "status": "queued"},  # POST command
            {"status": "completed"},  # GET command/42
            [{"id": 1}],  # GET trackfile (after) -> imported file
        ]

        (imported, errors), mock_request = self._run(responses)

        self.assertTrue(imported)
        self.assertEqual(errors, [])
        command_call = next(c for c in mock_request.call_args_list if c.args[:2] == ("POST", "command"))
        payload = json.loads(command_call.args[2])
        self.assertEqual(payload["files"][0]["artistId"], 628)
        self.assertEqual(payload["files"][0]["albumId"], 22909)
        self.assertEqual(payload["files"][0]["albumReleaseId"], 127617)

    def test_forced_album_score_rejection_requires_matching_ids_and_tracks(self):
        preview = [{"id": 1, "path": "/sidecar-import/a/01.flac"}]
        reprocessed = [
            {
                "id": 1,
                "path": "/sidecar-import/a/01.flac",
                "artist": {"id": 628},
                "album": {"id": 22909},
                "albumReleaseId": 127617,
                "rejections": [
                    {"reason": "Album match is not close enough: 75.1 % vs 80 % [country, tracks]"},
                    {"reason": "Has missing tracks"},
                ],
                "tracks": [{"id": 111, "albumId": 22909}],
            }
        ]

        (imported, errors), mock_request = self._run([preview, reprocessed])

        self.assertFalse(imported)
        self.assertEqual(len(errors), 2)
        self.assertFalse(any(c.args[:2] == ("POST", "command") for c in mock_request.call_args_list))

    def test_command_completed_without_new_files_is_failure(self):
        preview = [{"id": 1, "path": "/sidecar-import/a/01.flac"}]
        reprocessed = [
            {
                "id": 1,
                "path": "/sidecar-import/a/01.flac",
                "rejections": [],
                "tracks": [{"id": 111}],
            }
        ]
        responses = [
            preview,
            reprocessed,
            [],  # before -> 0
            {"id": 7, "status": "queued"},  # POST command
            {"status": "completed"},  # command finished
            [],  # after -> still 0 (nothing imported)
        ]

        (imported, rejections), _ = self._run(responses)

        self.assertFalse(imported)
        self.assertEqual(len(rejections), 1)
        self.assertIn("no new track files", rejections[0])

    @staticmethod
    def _strict_data():
        preview = [
            {"id": 1, "path": "/sidecar-import/Madonna - Album [mbid]/01.flac"},
            {"id": 2, "path": "/sidecar-import/Madonna - Album [mbid]/02.flac"},
        ]
        results = [
            {
                **item,
                "artist": {"id": 628},
                "album": {"id": 22909},
                "albumReleaseId": 127617,
                "tracks": [{"id": 111 * index}],
                "rejections": [],
            }
            for index, item in enumerate(preview, 1)
        ]
        tracks = [{"id": track_id, "artistId": 628, "albumId": 22909, "trackFileId": 0} for track_id in (111, 222)]
        return preview, results, tracks

    def test_strict_import_replaces_and_verifies_each_selected_track(self):
        preview, results, tracks = self._strict_data()
        imported_tracks = [{**track, "trackFileId": index} for index, track in enumerate(tracks, 1)]
        responses = [
            preview,
            results,
            tracks,
            [{"id": 91}, {"id": 92}],
            {"id": 42},
            {"status": "completed"},
            imported_tracks,
            [{"id": 1}, {"id": 2}],
        ]

        (imported, errors), request = self._run(responses, strict=True)

        self.assertTrue(imported)
        self.assertEqual(errors, [])
        self.assertIn("replaceExistingFiles=true", request.call_args_list[0].args[1])
        updates = json.loads(request.call_args_list[1].args[2])
        self.assertTrue(all(update["replaceExistingFiles"] for update in updates))
        command = next(call for call in request.call_args_list if call.args[:2] == ("POST", "command"))
        self.assertTrue(json.loads(command.args[2])["replaceExistingFiles"])

    def test_strict_import_can_replace_monitored_edition_with_exact_selected_release(self):
        preview, results, tracks = self._strict_data()
        for item in results:
            item["rejections"] = [{"reason": "Album release not requested"}]
        imported_tracks = [{**track, "trackFileId": index} for index, track in enumerate(tracks, 1)]
        responses = [
            preview,
            results,
            tracks,
            [{"id": 91}],
            {"id": 42},
            {"status": "completed"},
            imported_tracks,
            [{"id": 1}, {"id": 2}],
        ]
        (imported, errors), _ = self._run(responses, strict=True)
        self.assertTrue(imported)
        self.assertEqual(errors, [])

    def test_strict_import_refuses_partial_or_duplicate_track_mapping(self):
        preview, results, tracks = self._strict_data()
        for mapped in ([results[0]], [results[0], {**results[1], "tracks": [{"id": 111}]}]):
            with self.subTest(mapped=mapped):
                (imported, _), request = self._run([preview, mapped, tracks], strict=True)
                self.assertFalse(imported)
                self.assertFalse(any(call.args[:2] == ("POST", "command") for call in request.call_args_list))

    def test_strict_import_refuses_changed_release_identity_without_rejections(self):
        preview, results, _ = self._strict_data()
        results[1]["albumReleaseId"] = 999
        (imported, errors), request = self._run([preview, results], strict=True)
        self.assertFalse(imported)
        self.assertIn("forced artist, album, release", errors[0])
        self.assertFalse(any(call.args[:2] == ("POST", "command") for call in request.call_args_list))

    def test_strict_import_refuses_files_outside_staging_folder(self):
        preview, results, _ = self._strict_data()
        preview[0]["path"] = "/music/existing.flac"
        results[0]["path"] = preview[0]["path"]
        (imported, errors), request = self._run([preview, results], strict=True)
        self.assertFalse(imported)
        self.assertIn("previewed audio", errors[0])
        self.assertFalse(any(call.args[:2] == ("POST", "command") for call in request.call_args_list))

    def test_strict_import_does_not_report_partial_command_as_success(self):
        preview, results, tracks = self._strict_data()
        partially_imported = [{**tracks[0], "trackFileId": 1}, tracks[1]]
        responses = [preview, results, tracks, [], {"id": 42}, {"status": "completed"}, partially_imported, [{"id": 1}]]
        (imported, errors), _ = self._run(responses, strict=True)
        self.assertFalse(imported)
        self.assertIn("not all selected release tracks", errors[0])

    def test_strict_import_rejects_existing_file_ids_after_partial_replacement(self):
        preview, results, tracks = self._strict_data()
        after = [{**tracks[0], "trackFileId": 10}, {**tracks[1], "trackFileId": 2}]
        responses = [
            preview,
            results,
            tracks,
            [{"id": 1}, {"id": 2}],
            {"id": 42},
            {"status": "completed"},
            after,
            [{"id": 10}, {"id": 2}],
        ]
        (imported, errors), _ = self._run(responses, strict=True)
        self.assertFalse(imported)
        self.assertIn("not all selected release tracks", errors[0])


class RemoveLidarrQueueItemsTests(unittest.TestCase):
    def test_shared_api_exit_is_translated_to_service_error(self):
        with (
            patch.object(lidarr_api, "_shared_arr_api_request", side_effect=SystemExit(1)),
            self.assertRaisesRegex(RuntimeError, "Lidarr API request failed"),
        ):
            lidarr_api.arr_api_request("GET", "queue")

    def test_removes_matching_download_ids_across_queue_pages(self):
        responses = [
            {"records": [{"id": 1, "downloadId": "other"}], "totalRecords": 2, "pageSize": 1},
            {"records": [{"id": 2, "downloadId": "target"}], "totalRecords": 2, "pageSize": 1},
            None,
        ]
        state = {"response": None}
        calls = []

        def fake_request(method, path, _payload=None):
            calls.append((method, path))
            state["response"] = responses.pop(0)

        with (
            patch.object(lidarr_api, "arr_api_request", side_effect=fake_request),
            patch.object(
                lidarr_api, "get_state", side_effect=lambda key: state["response"] if key == "arrApiResponse" else None
            ),
        ):
            removed = lidarr_api.remove_lidarr_queue_items(["target"])

        self.assertEqual(removed, {"target"})
        self.assertEqual(
            calls,
            [
                ("GET", "queue?page=1&pageSize=1000&includeUnknownArtistItems=true"),
                ("GET", "queue?page=2&pageSize=1000&includeUnknownArtistItems=true"),
                ("DELETE", "queue/2?removeFromClient=true&blocklist=false"),
            ],
        )


class ScanImportVerifyTests(unittest.TestCase):
    def _run(self, responses):
        state = {"i": 0}

        def fake_get_state(key):
            if key != "arrApiResponse":
                return None
            value = responses[state["i"]]
            state["i"] += 1
            return value

        with (
            patch.object(lidarr_api, "arr_api_request"),
            patch.object(lidarr_api, "get_state", side_effect=fake_get_state),
            patch.object(lidarr_api.time, "sleep"),
        ):
            return lidarr_api.scan_import_and_verify("/sidecar-import/a", 22909)

    def test_scan_success_when_trackfiles_increase(self):
        responses = [
            [],  # before -> 0
            {"id": 5, "status": "queued"},  # POST command
            {"status": "completed"},  # command finished
            [{"id": 1}, {"id": 2}],  # after -> 2 files
        ]
        imported, errors = self._run(responses)
        self.assertTrue(imported)
        self.assertEqual(errors, [])

    def test_scan_failure_when_no_new_trackfiles(self):
        responses = [
            [],  # before -> 0
            {"id": 5, "status": "queued"},  # POST command
            {"status": "completed"},  # command finished
            [],  # after -> still 0
        ]
        imported, errors = self._run(responses)
        self.assertFalse(imported)
        self.assertEqual(len(errors), 1)
        self.assertIn("no new track files", errors[0])


if __name__ == "__main__":
    unittest.main()
