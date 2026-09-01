#!/usr/bin/env python3
import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


def _load_lidarr_service_module():
    workspace = Path(__file__).resolve().parents[3]
    python_root = workspace / "lidarr-sidecar" / "python"
    if str(python_root) not in sys.path:
        sys.path.insert(0, str(python_root))
    path = python_root / "deemix_downloader" / "service.py"
    spec = importlib.util.spec_from_file_location("deemix_downloader.service", str(path))
    if spec is None or spec.loader is None:
        raise ImportError(f"Cannot import Lidarr service from {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module

from shared.python.autoimport import common
from shared.python.autoimport.strategy import ImportStrategy


def _load_sonarr_strategy():
    workspace = Path(__file__).resolve().parents[3]
    path = workspace / "sonarr-sidecar" / "services" / "persistent" / "AutoImport.py"
    spec = importlib.util.spec_from_file_location(
        "sonarr_autoimport_strategy", str(path)
    )
    if spec is None or spec.loader is None:
        raise ImportError(f"Cannot import Sonarr strategy from {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.sonarr_strategy


sonarr_strategy = _load_sonarr_strategy()

radarr_strategy = ImportStrategy(
    resource_endpoint="movie",
    cache_filename="moviepaths",
    state_key="moviePaths",
)


class TestAutoImportCommon(unittest.TestCase):
    def test_cache_path_and_save_load(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            with patch.dict(os.environ, {"AUTOIMPORT_WORK_DIR": tmpdir}, clear=False):
                cache_path = common._cache_path("moviepaths")
                self.assertTrue(str(cache_path).endswith("moviepaths"))
                common._save_cached_paths(cache_path, ["/tmp/one", "/tmp/two"])
                self.assertEqual(
                    common._load_cached_paths(cache_path), ["/tmp/one", "/tmp/two"]
                )

    def test_find_match_returns_matching_path(self):
        paths = ["/mnt/share/TestMovie", "/mnt/share/OtherMovie"]
        self.assertEqual(common._find_match("TestMovie", paths), "/mnt/share/TestMovie")
        self.assertIsNone(common._find_match("Test", paths))
        self.assertIsNone(common._find_match("MissingMovie", paths))

    def test_get_import_target_name_strips_marker(self):
        with patch.dict(
            os.environ, {"AUTOIMPORT_IMPORT_MARKER": "IMPORT_"}, clear=False
        ):
            self.assertEqual(
                common.get_import_target_name("/tmp/IMPORT_BridgesOfMadisonCounty"),
                "BridgesOfMadisonCounty",
            )
            self.assertEqual(common.get_import_target_name("/tmp/NoMarker"), "NoMarker")

    def test_create_download_client_skips_existing_client(self):
        with patch.dict(
            os.environ,
            {
                "AUTOIMPORT_DOWNLOADCLIENT_NAME": "test-client",
                "AUTOIMPORT_SHARED_PATH": "/tmp/watched",
            },
            clear=False,
        ):
            calls = []

            def fake_arr_api_request(method, endpoint, payload=None):
                calls.append((method, endpoint, payload))

            with patch.object(
                common, "arr_api_request", side_effect=fake_arr_api_request
            ):
                with patch.object(
                    common, "get_state", return_value=[{"name": "test-client"}]
                ):
                    common.create_download_client()

            self.assertEqual(calls, [("GET", "downloadclient", None)])

    def test_process_import_moves_flagged_import(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            drop_dir = os.path.join(tmpdir, "drop")
            shared_dir = os.path.join(tmpdir, "shared")
            os.makedirs(drop_dir, exist_ok=True)
            os.makedirs(shared_dir, exist_ok=True)
            import_dir = os.path.join(drop_dir, "IMPORT_MySeries")
            os.makedirs(import_dir, exist_ok=True)
            with open(
                os.path.join(import_dir, "README.txt"), "w", encoding="utf-8"
            ) as fh:
                fh.write("content")

            env_vars = {
                "AUTOIMPORT_DROP_DIR": drop_dir,
                "AUTOIMPORT_SHARED_PATH": shared_dir,
                "AUTOIMPORT_IMPORT_MARKER": "IMPORT_",
                "AUTOIMPORT_CACHE_HOURS": "1",
                "AUTOIMPORT_WORK_DIR": tmpdir,
                "AUTOIMPORT_GROUP": str(os.getgid()),
                "ARR_NAME": "Sonarr",
            }

            with patch.dict(os.environ, env_vars, clear=False):
                with patch.object(
                    common, "ensure_resource_paths", return_value=["/tv/MySeries"]
                ):
                    with patch.object(common, "check_permissions", return_value=True):
                        arr_calls = []

                        def fake_arr_api_request(method, endpoint, payload=None):
                            arr_calls.append((method, endpoint, payload))

                        with patch.object(
                            common, "arr_api_request", side_effect=fake_arr_api_request
                        ):
                            common.process_import(import_dir, sonarr_strategy())

            self.assertFalse(os.path.exists(import_dir))
            self.assertTrue(os.path.isdir(os.path.join(shared_dir, "MySeries")))
            self.assertEqual(arr_calls, [])

    def test_process_import_writes_status_on_no_match(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            drop_dir = os.path.join(tmpdir, "drop")
            shared_dir = os.path.join(tmpdir, "shared")
            os.makedirs(drop_dir, exist_ok=True)
            os.makedirs(shared_dir, exist_ok=True)
            import_dir = os.path.join(drop_dir, "IMPORT_UniqueSeries")
            os.makedirs(import_dir, exist_ok=True)

            env_vars = {
                "AUTOIMPORT_DROP_DIR": drop_dir,
                "AUTOIMPORT_SHARED_PATH": shared_dir,
                "AUTOIMPORT_IMPORT_MARKER": "IMPORT_",
                "AUTOIMPORT_CACHE_HOURS": "1",
                "AUTOIMPORT_WORK_DIR": tmpdir,
                "AUTOIMPORT_GROUP": str(os.getgid()),
                "ARR_NAME": "Sonarr",
            }

            with patch.dict(os.environ, env_vars, clear=False):
                with patch.object(
                    common, "ensure_resource_paths", return_value=["/tv/OtherSeries"]
                ):
                    with patch.object(common, "check_permissions", return_value=True):
                        with patch.object(common, "arr_api_request"):
                            common.process_import(import_dir, sonarr_strategy())

            self.assertFalse(os.path.exists(import_dir))
            self.assertTrue(os.path.isdir(os.path.join(drop_dir, "UniqueSeries")))
            self.assertTrue(
                os.path.exists(
                    os.path.join(drop_dir, "UniqueSeries", "IMPORT_STATUS.txt")
                )
            )

    def test_process_import_preserves_raw_target_name_in_destination(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            drop_dir = os.path.join(tmpdir, "drop")
            shared_dir = os.path.join(tmpdir, "shared")
            os.makedirs(drop_dir, exist_ok=True)
            os.makedirs(shared_dir, exist_ok=True)
            import_dir = os.path.join(drop_dir, "IMPORT_Artist--release-group")
            os.makedirs(import_dir, exist_ok=True)

            strategy = ImportStrategy(
                resource_endpoint="artist",
                cache_filename="artistpaths",
                state_key="artistPaths",
                parse_folder_name=lambda target: (target.split("--", 1)[0], target),
            )
            env_vars = {
                "AUTOIMPORT_DROP_DIR": drop_dir,
                "AUTOIMPORT_SHARED_PATH": shared_dir,
                "AUTOIMPORT_IMPORT_MARKER": "IMPORT_",
                "AUTOIMPORT_CACHE_HOURS": "1",
                "AUTOIMPORT_WORK_DIR": tmpdir,
                "AUTOIMPORT_GROUP": str(os.getgid()),
                "ARR_NAME": "Lidarr",
            }

            with patch.dict(os.environ, env_vars, clear=False):
                with patch.object(
                    common, "ensure_resource_paths", return_value=["/music/Artist"]
                ), patch.object(common, "check_permissions", return_value=True):
                    common.process_import(import_dir, strategy)

            self.assertTrue(
                os.path.isdir(os.path.join(shared_dir, "Artist--release-group"))
            )

    def test_fetch_paginated_resource_paths_falls_back_when_page_size_ignored(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            env_vars = {
                "AUTOIMPORT_API_PAGE_SIZE": "100",
                "AUTOIMPORT_WORK_DIR": tmpdir,
                "ARR_NAME": "Radarr",
            }
            with patch.dict(os.environ, env_vars, clear=False):
                cache_file = Path(tmpdir) / "moviepaths"
                large_page = [{"path": f"/movies/movie{i}"} for i in range(11633)]

                call_sequence = []

                def fake_arr_api_request(method, endpoint, payload=None):
                    call_sequence.append((method, endpoint, payload))
                    common.set_state("arrApiResponse", large_page)

                with patch.object(
                    common, "arr_api_request", side_effect=fake_arr_api_request
                ):
                    paths = common._fetch_paginated_resource_paths(
                        radarr_strategy, cache_file
                    )

                self.assertEqual(paths, [item["path"] for item in large_page])
                self.assertEqual(
                    call_sequence, [("GET", "movie?page=1&pageSize=100", None)]
                )

    def test_fetch_paginated_resource_paths_falls_back_for_sonarr_series_endpoint(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            env_vars = {
                "AUTOIMPORT_API_PAGE_SIZE": "100",
                "AUTOIMPORT_WORK_DIR": tmpdir,
                "ARR_NAME": "Sonarr",
            }
            with patch.dict(os.environ, env_vars, clear=False):
                cache_file = Path(tmpdir) / "seriespaths"
                large_page = [{"path": f"/series/series{i}"} for i in range(11633)]

                call_sequence = []

                def fake_arr_api_request(method, endpoint, payload=None):
                    call_sequence.append((method, endpoint, payload))
                    common.set_state("arrApiResponse", large_page)

                with patch.object(
                    common, "arr_api_request", side_effect=fake_arr_api_request
                ):
                    paths = common._fetch_paginated_resource_paths(
                        sonarr_strategy(), cache_file
                    )

                self.assertEqual(paths, [item["path"] for item in large_page])
                self.assertEqual(
                    call_sequence, [("GET", "series?page=1&pageSize=100", None)]
                )

    def test_manual_import_rejects_non_mp3_flac_files_when_conversion_disabled(self):
        service = _load_lidarr_service_module()
        with tempfile.TemporaryDirectory() as tmpdir:
            import_dir = Path(tmpdir)
            (import_dir / "track.wav").write_bytes(b"not-audio")
            service.cfg.manual_import_convert_to_mp3 = False
            ok, message = service._validate_manual_import_files(import_dir)
            self.assertFalse(ok)
            self.assertIn("Unsupported manual import file", message)

    def test_manual_import_allows_converted_m4a_when_conversion_enabled(self):
        service = _load_lidarr_service_module()
        with tempfile.TemporaryDirectory() as tmpdir:
            import_dir = Path(tmpdir)
            (import_dir / "track.m4a").write_bytes(b"fake-m4a")
            service.cfg.manual_import_convert_to_mp3 = True
            ok, message = service._validate_manual_import_files(import_dir)
            self.assertTrue(ok)
            self.assertIn("Manual import files allowed", message)
