#!/usr/bin/env python3
import os
import runpy
import sys
import unittest
from types import ModuleType
from pathlib import Path
from unittest.mock import patch


class TestAutoImportEntrypoints(unittest.TestCase):
    def _run_wrapper_with_fake_main(self, wrapper_path: Path, module_name: str) -> None:
        fake_main_called = {"called": False}

        def fake_main():
            fake_main_called["called"] = True
            raise SystemExit(0)

        fake_shared = ModuleType("shared")
        fake_shared_python = ModuleType("shared.python")
        fake_shared_python_autoimport = ModuleType("shared.python.autoimport")
        fake_service_module = ModuleType(module_name)
        fake_service_module.main = fake_main

        modules = {
            "shared": fake_shared,
            "shared.python": fake_shared_python,
            "shared.python.autoimport": fake_shared_python_autoimport,
            module_name: fake_service_module,
        }

        with patch.dict(sys.modules, modules):
            with patch.dict(os.environ, {}, clear=False):
                os.environ.pop("SCRIPT_NAME", None)
                with self.assertRaises(SystemExit) as exc:
                    runpy.run_path(str(wrapper_path), run_name="__main__")
                self.assertEqual(exc.exception.code, 0)
                self.assertTrue(fake_main_called["called"])
                self.assertEqual(os.environ.get("SCRIPT_NAME"), "AutoImport")

    def test_sonarr_autimport_wrapper_invokes_main(self):
        workspace = Path(__file__).resolve().parents[3]
        wrapper = workspace / "sonarr-sidecar" / "services" / "AutoImport.py"
        self._run_wrapper_with_fake_main(wrapper, "shared.python.autoimport.sonarr")

    def test_radarr_autimport_wrapper_invokes_main(self):
        workspace = Path(__file__).resolve().parents[3]
        wrapper = workspace / "radarr-sidecar" / "services" / "AutoImport.py"
        self._run_wrapper_with_fake_main(wrapper, "shared.python.autoimport.radarr")
