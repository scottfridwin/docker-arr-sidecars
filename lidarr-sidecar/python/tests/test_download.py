#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from deemix_downloader import download
from deemix_downloader.config import Config


class DownloadTests(unittest.TestCase):
    def test_verify_flac_uses_long_timeout(self):
        with patch.object(
            download.subprocess,
            "run",
            return_value=type("Result", (), {"returncode": 0})(),
        ) as mock_run:
            self.assertTrue(download.verify_flac(Path("example.flac")))

        mock_run.assert_called_once_with(
            ["flac", "--totally-silent", "-t", "example.flac"],
            capture_output=True,
            timeout=300,
        )

    def test_verify_flac_returns_false_on_timeout(self):
        with patch.object(
            download.subprocess,
            "run",
            side_effect=download.subprocess.TimeoutExpired("flac", 300),
        ):
            self.assertFalse(download.verify_flac(Path("example.flac")))

    def test_remove_existing_import_flac_files_keeps_other_files(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            cfg = Config(shared_lidarr_path=Path(tmpdir))
            with patch.object(download, "cfg", cfg):
                import_path = download.get_import_path(
                    "Madonna", "I’m Breathless", "1990", "example-mbid"
                )
                import_path.mkdir()
                flac_file = import_path / "01 - Track.FLAC"
                mp3_file = import_path / "01 - Track.mp3"
                other_file = import_path / "cover.jpg"
                nested_flac = import_path / "nested"
                nested_flac.mkdir()
                nested_file = nested_flac / "02 - Track.flac"
                for file_path in (flac_file, mp3_file, other_file, nested_file):
                    file_path.touch()

                removed = download.remove_existing_import_flac_files(
                    "Madonna", "I’m Breathless", "1990", "example-mbid"
                )

                self.assertEqual(removed, 1)
                self.assertFalse(flac_file.exists())
                self.assertTrue(mp3_file.exists())
                self.assertTrue(other_file.exists())
                self.assertTrue(nested_file.exists())


if __name__ == "__main__":
    unittest.main()
