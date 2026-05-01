#!/usr/bin/env python3
import os
import sys
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
            service_base_dir = Path(tmpdir) / "services"
            one_time_dir = service_base_dir / "one-time"
            persistent_dir = service_base_dir / "persistent"
            one_time_dir.mkdir(parents=True)
            persistent_dir.mkdir(parents=True)

            auto_config = one_time_dir / "AutoConfig.py"
            auto_config.write_text("print('ok')\n", encoding="utf-8")
            auto_import = persistent_dir / "AutoImport.py"
            auto_import.write_text("print('ok')\n", encoding="utf-8")

            mock_run = MagicMock()
            mock_run.return_value.returncode = 0
            mock_popen = MagicMock()
            mock_popen.pid = 1234
            with patch(
                "shared.python.entrypoint.subprocess.run",
                mock_run,
            ), patch(
                "shared.python.entrypoint.subprocess.Popen",
                return_value=mock_popen,
            ) as popen_mock:
                processes = entrypoint._start_services(service_base_dir)

            mock_run.assert_called_once_with([sys.executable, str(auto_config)])
            self.assertIn(1234, processes)
            popen_mock.assert_called_once()
            popen_mock.assert_called_once_with([sys.executable, str(auto_import)])

    def test_start_services_runs_one_time_service_before_long_running(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            service_base_dir = Path(tmpdir) / "services"
            one_time_dir = service_base_dir / "one-time"
            persistent_dir = service_base_dir / "persistent"
            one_time_dir.mkdir(parents=True)
            persistent_dir.mkdir(parents=True)

            auto_config = one_time_dir / "AutoConfig.py"
            auto_config.write_text("print('config')\n", encoding="utf-8")
            auto_import = persistent_dir / "AutoImport.py"
            auto_import.write_text("print('import')\n", encoding="utf-8")

            mock_run = MagicMock()
            mock_run.return_value.returncode = 0
            mock_popen = MagicMock()
            mock_popen.pid = 4321

            with patch(
                "shared.python.entrypoint.subprocess.run",
                mock_run,
            ), patch(
                "shared.python.entrypoint.subprocess.Popen",
                return_value=mock_popen,
            ) as popen_mock:
                processes = entrypoint._start_services(service_base_dir)

            mock_run.assert_called_once_with([sys.executable, str(auto_config)])
            self.assertIn(4321, processes)
            popen_mock.assert_called_once_with([sys.executable, str(auto_import)])
