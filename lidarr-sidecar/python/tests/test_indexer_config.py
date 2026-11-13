#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

import importlib.util
import os
import sys
import unittest
from copy import deepcopy
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "lidarr-sidecar/services/one-time/IndexerConfig.py"
SPEC = importlib.util.spec_from_file_location("indexer_config", SCRIPT)
indexer_config = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = indexer_config
SPEC.loader.exec_module(indexer_config)


class IndexerConfigTests(unittest.TestCase):
    def test_upsert_does_not_treat_an_existing_resource_as_success_after_invalid_update(self):
        with (
            patch.object(indexer_config, "_request", side_effect=[[{"name": "client", "id": 1}], None]) as request,
            self.assertRaises(SystemExit),
        ):
            indexer_config._upsert("downloadclient", {"name": "client"})
        self.assertEqual(request.call_count, 2)

    def test_auto_configuration_is_opt_in(self):
        with (
            patch.dict(os.environ, {"AUTOCONFIG_DEEMIX_INDEXER": "false"}, clear=True),
            patch.object(indexer_config, "_request") as request,
            patch.object(indexer_config, "verify_arr_api_access") as verify,
        ):
            indexer_config.main()
        request.assert_not_called()
        verify.assert_not_called()

    def test_creates_dedicated_nzbget_client_and_bound_newznab_indexer(self):
        client_schema = {
            "implementation": "Nzbget",
            "implementationName": "NZBGet",
            "configContract": "NzbgetSettings",
            "protocol": "UsenetDownloadProtocol",
            "fields": [{"name": name, "value": None} for name in ("host", "port", "useSsl", "username", "password")],
        }
        indexer_schema = {
            "implementation": "Newznab",
            "implementationName": "Newznab",
            "configContract": "NewznabSettings",
            "protocol": "UsenetDownloadProtocol",
            "fields": [{"name": name, "value": None} for name in ("baseUrl", "apiPath", "apiKey", "categories")],
        }
        requests = []

        def fake_request(method, path, payload=None):
            requests.append((method, path, deepcopy(payload)))
            if path == "downloadclient/schema":
                return [client_schema]
            if path == "indexer/schema":
                return [indexer_schema]
            if method == "GET":
                return []
            if path == "downloadclient":
                return {"id": 41}
            if method == "POST" and path == "indexer":
                return {"id": 42}
            if method == "PUT" and path == "indexer/42?forceSave=true":
                return {"id": 42}
            raise AssertionError((method, path))

        environment = {
            "AUTOCONFIG_DEEMIX_INDEXER": "true",
            "SERVICE_INDEXER_ENABLED": "true",
            "SERVICE_DEEMIXDOWNLOADER_ENABLED": "false",
            "AUDIO_INDEXER_API_KEY": "k" * 32,
            "AUDIO_INDEXER_CLIENT_PASSWORD": "p" * 16,
            "AUDIO_INDEXER_PUBLIC_URL": "http://sidecar:9797",
            "AUDIO_INDEXER_CLIENT_HOST": "sidecar",
            "AUDIO_INDEXER_CLIENT_PORT": "",
            "AUDIO_INDEXER_PORT": "9797",
        }
        with (
            patch.dict(os.environ, environment, clear=True),
            patch.object(indexer_config, "_request", side_effect=fake_request),
            patch.object(indexer_config, "verify_arr_api_access"),
            patch.object(indexer_config, "init_state"),
        ):
            indexer_config.main()

        client = next(payload for method, path, payload in requests if method == "POST" and path == "downloadclient")
        indexer_post = next(payload for method, path, payload in requests if method == "POST" and path == "indexer")
        indexer = next(
            payload for method, path, payload in requests if method == "PUT" and path == "indexer/42?forceSave=true"
        )
        client_fields = {field["name"]: field["value"] for field in client["fields"]}
        indexer_fields = {field["name"]: field["value"] for field in indexer["fields"]}
        self.assertFalse(indexer_post["enable"])
        self.assertFalse(indexer_post["enableRss"])
        self.assertFalse(indexer_post["enableAutomaticSearch"])
        self.assertFalse(indexer_post["enableInteractiveSearch"])
        self.assertTrue(indexer["enable"])
        self.assertEqual((client_fields["host"], client_fields["port"]), ("sidecar", 9797))
        self.assertEqual(client_fields["password"], "p" * 16)
        self.assertFalse(client_fields.get("addPaused", False))
        self.assertEqual(indexer_fields["apiKey"], "k" * 32)
        self.assertEqual(indexer["downloadClientId"], 41)
        self.assertFalse(indexer["enableRss"])
        self.assertTrue(indexer["enableAutomaticSearch"])
        self.assertTrue(indexer["enableInteractiveSearch"])

    def test_one_time_configuration_waits_for_the_bridge(self):
        environment = {
            "AUTOCONFIG_DEEMIX_INDEXER": "true",
            "SERVICE_INDEXER_ENABLED": "true",
            "SERVICE_DEEMIXDOWNLOADER_ENABLED": "false",
        }
        with (
            patch.dict(os.environ, environment, clear=True),
            patch.object(indexer_config, "_request") as request,
            patch.object(indexer_config, "verify_arr_api_access") as verify,
        ):
            indexer_config.run_one_time()
        request.assert_not_called()
        verify.assert_not_called()


if __name__ == "__main__":
    unittest.main()
