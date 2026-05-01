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
            workspace / "sonarr-sidecar" / "services" / "persistent" / "AutoImport.py",
            "sonarr_autoimport_strategy",
        ).sonarr_strategy
        self.radarr_strategy = _load_strategy_module(
            workspace / "radarr-sidecar" / "services" / "persistent" / "AutoImport.py",
            "radarr_autoimport_strategy",
        ).radarr_strategy

    def test_sonarr_strategy_has_series_resource_settings(self):
        strategy = self.sonarr_strategy()
        self.assertEqual(strategy.resource_endpoint, "series")
        self.assertEqual(strategy.cache_filename, "seriepaths")
        self.assertEqual(strategy.state_key, "seriesPaths")

    def test_radarr_strategy_has_movie_resource_settings(self):
        strategy = self.radarr_strategy()
        self.assertEqual(strategy.resource_endpoint, "movie")
        self.assertEqual(strategy.cache_filename, "moviepaths")
        self.assertEqual(strategy.state_key, "moviePaths")
