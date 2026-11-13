#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from deemix_downloader import lidarr_api


class ManualImportReleaseTests(unittest.TestCase):
    def _run(self, responses):
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


class RemoveLidarrQueueItemsTests(unittest.TestCase):
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

        self.assertEqual(removed, 1)
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
