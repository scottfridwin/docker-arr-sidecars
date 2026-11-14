import os
import re
import sys
import tempfile
import threading
import time
import unittest
from contextlib import nullcontext
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from deemix_downloader import download, service
from deemix_downloader.config import Config
from deemix_downloader.matching import MatchResult


class ServiceDownloadRetryTests(unittest.TestCase):
    def test_expired_cache_and_markers_are_cleaned_using_their_settings(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            config = Config(work_path=Path(temp_dir) / "work", data_path=Path(temp_dir) / "data")
            config.cache_dir.mkdir(parents=True)
            config.failed_dir.mkdir(parents=True)
            old_cache = config.cache_dir / "deezer-album-1.json"
            recent_cache = config.cache_dir / "mb-recent.json"
            old_marker = config.failed_dir / "1"
            for path in (old_cache, recent_cache, old_marker):
                path.touch()
            old_time = time.time() - 181 * 86400
            os.utime(old_cache, (old_time, old_time))
            os.utime(old_marker, (old_time, old_time))
            with patch.object(download, "cfg", config), patch.object(service, "cfg", config):
                download.prune_cache()
                service.folder_cleaner()
            self.assertFalse(old_cache.exists())
            self.assertFalse(old_marker.exists())
            self.assertTrue(recent_cache.exists())

    def test_abandoned_attempts_are_pruned_only_without_active_or_recovery_jobs(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            config = Config(work_path=Path(temp_dir))
            bridge = Mock(retention_days=30)
            bridge.store.locked.return_value = nullcontext()
            old = config.work_path / "deemix-attempt-abcdefgh"
            recent = config.work_path / "deemix-attempt-12345678"
            quota_temp = config.work_path / "deemix-quota-abcdefgh"
            quota_temp.touch()
            old.mkdir()
            recent.mkdir()
            (old / "track.flac").touch()
            old_time = time.time() - 31 * 86400
            os.utime(old / "track.flac", (old_time, old_time))
            os.utime(old, (old_time, old_time))
            os.utime(quota_temp, (old_time, old_time))
            bridge.store.jobs.return_value = [{"status": "needs_recovery"}]
            with patch.object(service, "cfg", config):
                service.clean_abandoned_attempts(bridge)
                self.assertTrue(old.exists())
                bridge.store.jobs.return_value = []
                service.clean_abandoned_attempts(bridge)
            self.assertFalse(old.exists())
            self.assertTrue(recent.exists())
            self.assertFalse(quota_temp.exists())

    def test_legacy_counts_completed_download_even_when_import_fails(self):
        tracker = Mock()
        album = {"id": 2, "title": "Album", "artist": {"id": 1}}
        match = MatchResult(matched=True, deezer_album_id="42", deezer_track_count=1)

        def download(*_args, on_download_complete, **_kwargs):
            on_download_complete()
            return False

        with tempfile.TemporaryDirectory() as directory:
            config = Config(work_path=Path(directory), data_path=Path(directory))
            with (
                patch.object(service, "cfg", config),
                patch.object(service, "get_album_data", return_value=album),
                patch.object(service, "search_album", return_value=match),
                patch.object(service, "_write_result_file"),
                patch.object(service, "_download_album", side_effect=download),
            ):
                service.search_and_download("2", set(), tracker, "token")
        tracker.increment.assert_called_once_with()

    def _run_download(self, track_count, attempt_outputs, *, attempt_threshold, quality_fallback):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            config = Config(
                work_path=root / "work",
                data_path=root / "data",
                shared_lidarr_path=root / "shared",
                download_attempt_threshold=attempt_threshold,
                download_quality_fallback=quality_fallback,
                import_strategy="scan",
            )
            config.work_path.mkdir()
            config.shared_lidarr_path.mkdir()

            calls = []

            def fake_download(_album_id, _arl_token, quality, _deemix_dir, *, output_dir):
                calls.append((quality, output_dir))
                for track_number in attempt_outputs[len(calls) - 1][1]:
                    (output_dir / f"track-{track_number:02d}-attempt-{len(calls)}.{quality}").touch()
                return True

            def track_numbers(file_path):
                match = re.search(r"track-(\d+)", file_path.name)
                return (1, int(match.group(1))) if match else (None, None)

            result = MatchResult(
                deezer_album_id="42",
                deezer_title="Test Album",
                deezer_year="2000",
                deezer_track_count=track_count,
            )
            with (
                patch.object(service, "cfg", config),
                patch.object(download, "cfg", config),
                patch.object(service, "download_with_deemix", side_effect=fake_download),
                patch.object(service, "get_file_disc_track_numbers", side_effect=track_numbers),
                patch.object(service, "verify_flac", return_value=True),
                patch.object(service, "_tag_and_enrich"),
                patch.object(service, "notify_lidarr_import"),
                patch.object(service.time, "sleep"),
            ):
                succeeded = service._download_album(
                    result,
                    artist_name="Test Artist",
                    artist_id="",
                    artist_foreign_id="artist-mbid",
                    album_title="Test Album",
                    album_foreign_id="release-group-mbid",
                    album_id="123",
                    arl_token="token",
                )

            imported_files = list(config.shared_lidarr_path.rglob("*"))
            audio_files = [
                path for path in imported_files if path.is_file() and path.suffix.lower() in download.AUDIO_EXTENSIONS
            ]
            failed_marker_exists = (config.failed_dir / result.deezer_album_id).exists()
            return succeeded, calls, audio_files, failed_marker_exists

    def test_partial_downloads_accumulate_distinct_tracks_between_attempts(self):
        attempt_outputs = [
            ("flac", set(range(1, 9))),
            ("flac", set(range(1, 11))),
            ("flac", {*range(1, 9), 10, 11}),
        ]

        succeeded, calls, audio_files, failed_marker_exists = self._run_download(
            11,
            attempt_outputs,
            attempt_threshold=3,
            quality_fallback=False,
        )

        self.assertTrue(succeeded)
        self.assertEqual(len(calls), 3)
        self.assertEqual([quality for quality, _ in calls], ["flac", "flac", "flac"])
        self.assertEqual(len({output_dir for _, output_dir in calls}), 3)
        self.assertEqual(len(audio_files), 11)
        self.assertFalse(failed_marker_exists)

    def test_quality_fallback_starts_fresh_accumulator_and_uses_full_attempt_limit(self):
        attempt_outputs = [
            ("flac", {1}),
            ("flac", {1}),
            ("mp3", {1}),
            ("mp3", {2}),
        ]

        succeeded, calls, audio_files, failed_marker_exists = self._run_download(
            2,
            attempt_outputs,
            attempt_threshold=2,
            quality_fallback=True,
        )

        self.assertTrue(succeeded)
        self.assertEqual([quality for quality, _ in calls], ["flac", "flac", "mp3", "mp3"])
        self.assertEqual(len(audio_files), 2)
        self.assertTrue(all(path.suffix.lower() == ".mp3" for path in audio_files))
        self.assertFalse(failed_marker_exists)

    def test_failed_marker_is_created_only_after_full_attempt_limit(self):
        attempt_outputs = [("flac", {1}), ("flac", {1})]

        succeeded, calls, audio_files, failed_marker_exists = self._run_download(
            2,
            attempt_outputs,
            attempt_threshold=2,
            quality_fallback=False,
        )

        self.assertFalse(succeeded)
        self.assertEqual(len(calls), 2)
        self.assertEqual(audio_files, [])
        self.assertTrue(failed_marker_exists)

    def test_strict_manual_import_requires_ids_before_download(self):
        result = MatchResult(deezer_album_id="42", lidarr_release_id="")
        with patch.object(service, "download_with_deemix") as download:
            succeeded = service._download_album(
                result, "Artist", "1", "artist-mbid", "Album", "group-mbid", "2", "token", strict_manual_import=True
            )
        self.assertFalse(succeeded)
        download.assert_not_called()

    def test_strict_import_refuses_leftover_staged_audio_before_downloading(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            config = Config(shared_lidarr_path=Path(temp_dir))
            result = MatchResult(deezer_album_id="42", deezer_track_count=1, lidarr_release_id="3")
            stale = Path(temp_dir) / "old"
            stale.mkdir()
            (stale / "track.mp3").touch()
            with (
                patch.object(service, "cfg", config),
                patch.object(service, "get_import_path", return_value=stale),
                patch.object(service, "download_with_deemix") as download,
            ):
                succeeded = service._download_album(
                    result, "Artist", "1", "artist-mbid", "Album", "group-mbid", "2", "token", strict_manual_import=True
                )
            self.assertFalse(succeeded)
            download.assert_not_called()

    def test_unknown_track_count_never_starts_or_completes_download(self):
        for count in (0, -1, None):
            with self.subTest(count=count):
                result = MatchResult(deezer_album_id="42", deezer_track_count=count, lidarr_release_id="3")
                with patch.object(service, "download_with_deemix") as download:
                    completed = Mock()
                    succeeded = service._download_album(
                        result,
                        "Artist",
                        "1",
                        "artist",
                        "Album",
                        "group",
                        "2",
                        "token",
                        strict_manual_import=True,
                        on_download_complete=completed,
                    )
                self.assertFalse(succeeded)
                completed.assert_not_called()
                download.assert_not_called()

    def test_completed_audio_remains_in_staging_if_quota_completion_raises(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            config = Config(
                work_path=root / "work",
                shared_lidarr_path=root / "shared",
                download_attempt_threshold=1,
            )
            config.work_path.mkdir()
            config.shared_lidarr_path.mkdir()
            result = MatchResult(deezer_album_id="42", deezer_track_count=1, lidarr_release_id="3")

            def fake_download(*_args, output_dir, **_kwargs):
                (output_dir / "track.flac").touch()
                return True

            with (
                patch.object(service, "cfg", config),
                patch.object(download, "cfg", config),
                patch.object(service, "download_with_deemix", side_effect=fake_download),
                patch.object(service, "verify_flac", return_value=True),
                self.assertRaisesRegex(RuntimeError, "quota unavailable"),
            ):
                service._download_album(
                    result,
                    "Artist",
                    "1",
                    "artist",
                    "Album",
                    "group",
                    "2",
                    "token",
                    strict_manual_import=True,
                    on_download_complete=Mock(side_effect=RuntimeError("quota unavailable")),
                )
            self.assertTrue((config.staging_dir / "track.flac").is_file())

    def test_search_remains_available_during_manual_import(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            config = Config(work_path=root / "work", shared_lidarr_path=root / "shared", download_attempt_threshold=1)
            config.work_path.mkdir()
            config.shared_lidarr_path.mkdir()
            result = MatchResult(deezer_album_id="42", deezer_track_count=1, lidarr_release_id="3")
            importing = threading.Event()
            release_import = threading.Event()
            searched = threading.Event()

            def fake_download(*_args, output_dir, **_kwargs):
                (output_dir / "track.flac").touch()
                return True

            def manual_import(**_kwargs):
                importing.set()
                release_import.wait(2)
                return True, []

            def search():
                service._indexer_api_get("artist")
                searched.set()

            with (
                patch.object(service, "cfg", config),
                patch.object(download, "cfg", config),
                patch.object(service, "download_with_deemix", side_effect=fake_download),
                patch.object(service, "verify_flac", return_value=True),
                patch.object(service, "_tag_and_enrich"),
                patch.object(service, "manual_import_release", side_effect=manual_import),
                patch.object(service, "request_response", return_value=[]),
            ):
                worker = threading.Thread(
                    target=service._download_album,
                    args=(result, "Artist", "1", "artist", "Album", "group", "2", "token"),
                    kwargs={"strict_manual_import": True},
                )
                search_worker = threading.Thread(target=search)
                worker.start()
                try:
                    self.assertTrue(importing.wait(2))
                    search_worker.start()
                    self.assertTrue(searched.wait(0.5))
                finally:
                    release_import.set()
                    worker.join(2)
                    if search_worker.ident is not None:
                        search_worker.join(2)

    def test_indexer_does_not_modify_priority_file(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            priority = root / "priority.txt"
            priority.write_text("2 # keep this entry\n")
            config = Config(
                work_path=root / "work",
                data_path=root / "data",
                shared_lidarr_path=root / "shared",
                priority_file=str(priority),
                download_attempt_threshold=1,
            )
            config.work_path.mkdir()
            config.shared_lidarr_path.mkdir()
            result = MatchResult(deezer_album_id="42", deezer_track_count=1, lidarr_release_id="3")

            def fake_download(*_args, output_dir, **_kwargs):
                (output_dir / "track.flac").touch()
                return True

            with (
                patch.object(service, "cfg", config),
                patch.object(download, "cfg", config),
                patch.object(service, "download_with_deemix", side_effect=fake_download),
                patch.object(service, "verify_flac", return_value=True),
                patch.object(service, "_tag_and_enrich"),
                patch.object(service, "manual_import_release", return_value=(True, [])),
            ):
                succeeded = service._download_album(
                    result,
                    "Artist",
                    "1",
                    "artist",
                    "Album",
                    "group",
                    "2",
                    "token",
                    strict_manual_import=True,
                    staging_owner_id="a" * 32,
                )
            self.assertTrue(succeeded)
            self.assertEqual(priority.read_text(), "2 # keep this entry\n")
            self.assertFalse(config.downloaded_dir.exists())
            self.assertFalse(config.failed_dir.exists())
            self.assertEqual(list(config.shared_lidarr_path.rglob(".deemix-owner-*")), [])

    def test_job_staging_survives_later_download_cleanup(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            config = Config(
                work_path=root / "work",
                data_path=root / "data",
                shared_lidarr_path=root / "shared",
                download_attempt_threshold=1,
                download_quality_fallback=False,
            )
            config.work_path.mkdir()
            config.shared_lidarr_path.mkdir()
            result = MatchResult(
                deezer_album_id="42",
                deezer_title="Album",
                deezer_track_count=1,
                lidarr_release_id="3",
                lidarr_release_foreign_id="release-mbid",
            )

            def fake_download(_album_id, _arl_token, _quality, _deemix_dir, *, output_dir):
                (output_dir / "track.flac").touch()
                return True

            with (
                patch.object(service, "cfg", config),
                patch.object(download, "cfg", config),
                patch.object(service, "download_with_deemix", side_effect=fake_download),
                patch.object(service, "verify_flac", return_value=True),
                patch.object(service, "_tag_and_enrich"),
                patch.object(service, "manual_import_release", return_value=(True, [])),
            ):
                with self.assertRaisesRegex(RuntimeError, "quota completion failed"):
                    service._download_album(
                        result,
                        "Artist",
                        "1",
                        "artist-mbid",
                        "Album",
                        "group-mbid",
                        "2",
                        "token",
                        strict_manual_import=True,
                        staging_owner_id="a" * 32,
                        on_download_complete=Mock(side_effect=RuntimeError("quota completion failed")),
                    )
                recovery_audio = config.staging_dir / "jobs" / ("a" * 32) / "track.flac"
                self.assertTrue(recovery_audio.exists())
                self.assertTrue(
                    service._download_album(
                        result,
                        "Artist",
                        "1",
                        "artist-mbid",
                        "Album",
                        "group-mbid",
                        "2",
                        "token",
                        strict_manual_import=True,
                        staging_owner_id="b" * 32,
                    )
                )
                self.assertTrue(recovery_audio.exists())

    def test_strict_manual_import_never_falls_back_to_scan(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            config = Config(
                work_path=root / "work",
                data_path=root / "data",
                shared_lidarr_path=root / "shared",
                download_attempt_threshold=1,
                import_strategy="scan",
                import_manual_fallback_to_scan=True,
            )
            config.work_path.mkdir()
            config.shared_lidarr_path.mkdir()
            result = MatchResult(
                deezer_album_id="42",
                deezer_title="Album",
                deezer_track_count=1,
                lidarr_release_id="3",
                lidarr_release_foreign_id="release-mbid",
            )

            def fake_download(_album_id, _arl_token, _quality, _deemix_dir, *, output_dir):
                (output_dir / "track.flac").touch()
                return True

            with (
                patch.object(service, "cfg", config),
                patch.object(download, "cfg", config),
                patch.object(service, "download_with_deemix", side_effect=fake_download),
                patch.object(service, "verify_flac", return_value=True),
                patch.object(service, "_tag_and_enrich"),
                patch.object(service, "manual_import_release", return_value=(False, ["rejected"])) as manual,
                patch.object(service, "scan_import_and_verify") as scan,
                patch.object(service, "notify_lidarr_import") as notify,
            ):
                succeeded = service._download_album(
                    result,
                    "Artist",
                    "1",
                    "artist-mbid",
                    "Album",
                    "group-mbid",
                    "2",
                    "token",
                    strict_manual_import=True,
                    staging_owner_id="a" * 32,
                )

            self.assertFalse(succeeded)
            self.assertFalse(config.failed_dir.exists())
            self.assertEqual(len(list(config.shared_lidarr_path.rglob(".deemix-owner-*"))), 1)
            manual.assert_called_once()
            self.assertEqual(manual.call_args.kwargs["artist_id"], "1")
            self.assertEqual(manual.call_args.kwargs["album_id"], "2")
            self.assertEqual(manual.call_args.kwargs["release_id"], "3")
            scan.assert_not_called()
            notify.assert_not_called()


if __name__ == "__main__":
    unittest.main()
