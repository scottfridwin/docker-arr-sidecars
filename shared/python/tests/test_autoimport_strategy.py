#!/usr/bin/env python3
import importlib.util
import unittest
from pathlib import Path


def _load_strategy_module(path: Path, module_name: str):
    spec = importlib.util.spec_from_file_location(module_name, str(path))
    if spec is None or spec.loader is None:
        raise ImportError(f"Cannot import strategy module from {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class TestAutoImportStrategy(unittest.TestCase):
    def setUp(self):
        workspace = Path(__file__).resolve().parents[3]
        self.sonarr_strategy = _load_strategy_module(
            workspace / "sonarr-sidecar" / "services" / "AutoImport.py",
            "sonarr_autoimport_strategy",
        ).sonarr_strategy
        self.radarr_strategy = _load_strategy_module(
            workspace / "radarr-sidecar" / "services" / "AutoImport.py",
            "radarr_autoimport_strategy",
        ).radarr_strategy

    def test_sonarr_strategy_payload_contains_title_and_timestamp(self):
        payload = self.sonarr_strategy().push_release_payload("MySeries")
        self.assertIn('"title":"MySeries"', payload)
        self.assertRegex(
            payload, r'"publishDate":"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"'
        )

    def test_radarr_strategy_payload_is_valid_json_string(self):
        payload = self.radarr_strategy().notify_payload("/tmp/import")
        self.assertIn('"DownloadedMoviesScan"', payload)
        self.assertIn('"path":"/tmp/import"', payload)
