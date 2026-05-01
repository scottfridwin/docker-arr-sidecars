#!/usr/bin/env python3
import os
import runpy
import sys
import unittest
from types import ModuleType
from pathlib import Path
from unittest.mock import patch


class TestAutoImportEntrypoints(unittest.TestCase):
    def _run_wrapper_with_fake_main(
        self, wrapper_path: Path, expected_resource: str
    ) -> None:

        def fake_main(strategy):
            fake_main.called = True
            fake_main.arg = strategy
            raise SystemExit(0)

        fake_runner = ModuleType("shared.python.autoimport.runner")
        fake_runner.main = fake_main

        fake_shared = ModuleType("shared")
        fake_shared_python = ModuleType("shared.python")
        fake_shared_autoimport = ModuleType("shared.python.autoimport")

        modules = {
            "shared": fake_shared,
            "shared.python": fake_shared_python,
            "shared.python.autoimport": fake_shared_autoimport,
            "shared.python.autoimport.runner": fake_runner,
        }

        with patch.dict(sys.modules, modules):
            with patch.dict(os.environ, {}, clear=False):
                os.environ.pop("SCRIPT_NAME", None)
                with self.assertRaises(SystemExit) as exc:
                    runpy.run_path(str(wrapper_path), run_name="__main__")
                self.assertEqual(exc.exception.code, 0)
                self.assertTrue(getattr(fake_main, "called", False))
                self.assertEqual(fake_main.arg.resource_endpoint, expected_resource)
                self.assertEqual(os.environ.get("SCRIPT_NAME"), "AutoImport")

    def test_sonarr_autimport_wrapper_invokes_runner(self):
        workspace = Path(__file__).resolve().parents[3]
        wrapper = (
            workspace / "sonarr-sidecar" / "services" / "persistent" / "AutoImport.py"
        )
        self._run_wrapper_with_fake_main(wrapper, "series")

    def test_radarr_autimport_wrapper_invokes_runner(self):
        workspace = Path(__file__).resolve().parents[3]
        wrapper = (
            workspace / "radarr-sidecar" / "services" / "persistent" / "AutoImport.py"
        )
        self._run_wrapper_with_fake_main(wrapper, "movie")
