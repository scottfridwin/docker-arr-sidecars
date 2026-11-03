import re
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from deemix_downloader import download, service
from deemix_downloader.config import Config
from deemix_downloader.matching import MatchResult


class ServiceDownloadRetryTests(unittest.TestCase):
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
                path
                for path in imported_files
                if path.is_file() and path.suffix.lower() in download.AUDIO_EXTENSIONS
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


if __name__ == "__main__":
    unittest.main()
