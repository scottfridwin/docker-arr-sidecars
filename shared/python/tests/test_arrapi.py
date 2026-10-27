#!/usr/bin/env python3
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from shared.python import state as state_module
from shared.python.arrapi import (
    _redact_payload,
    find_existing_resource,
    get_arr_api_key,
    get_arr_url,
    get_functional_test_response,
    ids_equal,
    is_masked_secret,
    resolve_profile_format_items,
    response_matches_payload,
    update_arr_config,
)


class TestArrApi(unittest.TestCase):
    def tearDown(self):
        state_module.init_state()

    def test_redact_payload_masks_secrets(self):
        import json

        payload = json.dumps(
            {
                "apiKey": "topsecret",
                "name": "qbit",
                "fields": [
                    {"name": "password", "value": "hunter2"},
                    {"name": "host", "value": "qbittorrent"},
                ],
            }
        )
        out = json.loads(_redact_payload(payload))
        self.assertEqual(out["apiKey"], "***")
        self.assertEqual(out["fields"][0]["value"], "***")  # password field masked
        self.assertEqual(out["fields"][1]["value"], "qbittorrent")  # host preserved
        self.assertNotIn("hunter2", _redact_payload(payload))

    def test_ids_equal(self):
        self.assertTrue(ids_equal(1, "1"))
        self.assertTrue(ids_equal("42", 42))
        self.assertFalse(ids_equal("x", "y"))
        self.assertFalse(ids_equal(None, "1"))

    def test_response_matches_payload_object(self):
        payload = {"name": "test", "value": 5}
        response = {"name": "test", "value": 5}
        self.assertTrue(response_matches_payload(payload, response))

    def test_response_matches_payload_fields_array(self):
        payload = {"fields": [{"name": "foo", "value": "bar"}]}
        response = {"fields": [{"name": "foo", "value": "bar"}]}
        self.assertTrue(response_matches_payload(payload, response))

    def test_is_masked_secret(self):
        self.assertTrue(is_masked_secret("apiKey", "********"))
        self.assertTrue(is_masked_secret("Password", "****"))
        self.assertFalse(is_masked_secret("apiKey", "realvalue"))
        self.assertFalse(is_masked_secret("username", "********"))
        self.assertFalse(is_masked_secret("apiKey", ""))

    def test_response_matches_payload_fields_array_masked_secret(self):
        payload = {
            "fields": [
                {"name": "apiKey", "value": "supersecret"},
                {"name": "password", "value": "hunter2"},
                {"name": "host", "value": "localhost"},
            ]
        }
        response = {
            "fields": [
                {"name": "apiKey", "value": "********"},
                {"name": "password", "value": "********"},
                {"name": "host", "value": "localhost"},
            ]
        }
        self.assertTrue(response_matches_payload(payload, response))

    def test_response_matches_payload_top_level_masked_secret(self):
        payload = {"apiKey": "supersecret"}
        response = {"apiKey": "********"}
        self.assertTrue(response_matches_payload(payload, response))

    def test_response_matches_payload_non_masked_mismatch_still_fails(self):
        payload = {"fields": [{"name": "apiKey", "value": "supersecret"}]}
        response = {"fields": [{"name": "apiKey", "value": "differentvalue"}]}
        self.assertFalse(response_matches_payload(payload, response))

    def test_find_existing_resource_matches_by_id(self):
        item = {"id": 3, "name": "my-client"}
        response = [{"id": 3, "name": "other-name"}, {"id": 5, "name": "my-client"}]
        match = find_existing_resource(item, response)
        self.assertEqual(match, {"id": 3, "name": "other-name"})

    def test_find_existing_resource_falls_back_to_name(self):
        item = {"id": 1, "name": "my-client"}
        response = [{"id": 5, "name": "my-client"}, {"id": 6, "name": "unrelated"}]
        match = find_existing_resource(item, response)
        self.assertEqual(match, {"id": 5, "name": "my-client"})

    def test_find_existing_resource_no_match(self):
        item = {"id": 1, "name": "my-client"}
        response = [{"id": 5, "name": "unrelated"}]
        self.assertIsNone(find_existing_resource(item, response))

    def test_resolve_profile_format_items_uses_live_ids_and_adds_missing_formats(self):
        profile = {
            "id": 1,
            "name": "Any",
            "formatItems": [
                {"format": 1, "name": "HEVC", "score": 500},
                {"format": 2, "name": "Tdarr Re-encode", "score": -1000},
            ],
        }
        custom_formats = [
            {"id": 17, "name": "HEVC"},
            {"id": 21, "name": "Unscored"},
            {"id": 19, "name": "Tdarr Re-encode"},
        ]

        resolved = resolve_profile_format_items(profile, custom_formats)

        self.assertEqual(
            resolved["formatItems"],
            [
                {"format": 17, "name": "HEVC", "score": 500},
                {"format": 19, "name": "Tdarr Re-encode", "score": -1000},
                {"format": 21, "name": "Unscored", "score": 0},
            ],
        )
        self.assertEqual(profile["formatItems"][0]["format"], 1)

    def test_resolve_profile_format_items_rejects_unknown_format(self):
        profile = {"name": "Any", "formatItems": [{"format": 1, "name": "Missing", "score": 1}]}
        with self.assertRaises(SystemExit):
            resolve_profile_format_items(profile, [{"id": 1, "name": "Other"}])

    def test_resolve_profile_format_items_rejects_duplicate_format(self):
        profile = {
            "name": "Any",
            "formatItems": [{"format": 1, "name": "HEVC", "score": 1}, {"format": 1, "name": "HEVC", "score": 2}],
        }
        with self.assertRaises(SystemExit):
            resolve_profile_format_items(profile, [{"id": 1, "name": "HEVC"}])

    @patch("shared.python.arrapi.arr_api_attempt")
    @patch("shared.python.arrapi.arr_api_request")
    @patch("shared.python.arrapi.read_json_file")
    def test_update_quality_profiles_resolves_format_ids_before_put(self, read_mock, request_mock, attempt_mock):
        read_mock.return_value = [{"id": 1, "name": "Any", "formatItems": [{"format": 1, "name": "HEVC", "score": 5}]}]
        responses = {
            "qualityprofile": [{"id": 1, "name": "Any"}],
            "customformat": [{"id": 17, "name": "HEVC"}],
        }
        request_mock.side_effect = lambda _method, path: state_module.set_state("arrApiResponse", responses[path])
        state_module.init_state()

        update_arr_config("/config/qualityprofile.json", "qualityprofile", "Quality Profile(s)")

        attempt_mock.assert_called_once()
        method, url, payload = attempt_mock.call_args.args
        self.assertEqual((method, url), ("PUT", "qualityprofile/1"))
        self.assertEqual(
            json.loads(payload)["formatItems"],
            [{"format": 17, "name": "HEVC", "score": 5}],
        )

    def test_get_functional_test_response(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            test_dir = Path(temp_dir)
            responses = test_dir / "ArrApiRequestResponses"
            responses.mkdir()
            path = responses / "GET_command.json"
            path.write_text('{"status": "ok"}', encoding="utf-8")
            with patch.dict(os.environ, {"FUNCTIONALTESTDIR": temp_dir}, clear=False):
                status, body = get_functional_test_response("GET", "command")
                self.assertEqual(status, 200)
                self.assertEqual(body, '{"status": "ok"}')

    def test_get_arr_api_key_and_url(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            xml_path = Path(temp_dir) / "config.xml"
            xml_path.write_text(
                "<Config><ApiKey>secret</ApiKey><UrlBase>/path</UrlBase><Port>1234</Port></Config>",
                encoding="utf-8",
            )
            with patch.dict(
                os.environ,
                {
                    "ARR_CONFIG_PATH": str(xml_path),
                    "ARR_HOST": "localhost",
                    "ARR_PORT": "",
                },
                clear=False,
            ):
                state_module.init_state()
                self.assertEqual(get_arr_api_key(), "secret")
                self.assertEqual(get_arr_url(), "http://localhost:1234/path")
