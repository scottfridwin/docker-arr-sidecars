#!/usr/bin/env python3
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

from shared.python import entrypoint


class TestEntrypoint(unittest.TestCase):
    def test_validate_environment_passes_with_valid_settings(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config_path = Path(tmpdir) / "config.xml"
            config_path.write_text("<Config></Config>", encoding="utf-8")
            with patch.dict(
                os.environ,
                {
                    "ARR_CONFIG_PATH": str(config_path),
                    "UMASK": "0002",
                    "LOG_LEVEL": "INFO",
                },
                clear=False,
            ):
                entrypoint._validate_environment()

    def test_validate_environment_fails_with_invalid_umask(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config_path = Path(tmpdir) / "config.xml"
            config_path.write_text("<Config></Config>", encoding="utf-8")
            with patch.dict(
                os.environ,
                {
                    "ARR_CONFIG_PATH": str(config_path),
                    "UMASK": "bad",
                    "LOG_LEVEL": "INFO",
                },
                clear=False,
            ):
                with self.assertRaises(SystemExit):
                    entrypoint._validate_environment()

    def test_start_services_spawns_python_files(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            service_dir = Path(tmpdir) / "services"
            service_dir.mkdir()
            service_file = service_dir / "AutoConfig.py"
            service_file.write_text("print('ok')\n", encoding="utf-8")

            with patch.object(
                entrypoint.Path, "is_dir", return_value=True
            ), patch.object(entrypoint.Path, "glob", return_value=[service_file]):
                mock_popen = MagicMock()
                mock_popen.pid = 1234
                with patch(
                    "shared.python.entrypoint.subprocess.Popen", return_value=mock_popen
                ) as popen_mock:
                    processes = entrypoint._start_services()

                self.assertIn(1234, processes)
                popen_mock.assert_called_once()
