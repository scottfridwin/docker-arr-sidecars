#!/usr/bin/env python3
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from shared.python import state as state_module
from shared.python.arrapi import (
    get_arr_api_key,
    get_arr_url,
    get_functional_test_response,
    ids_equal,
    response_matches_payload,
)


class TestArrApi(unittest.TestCase):
    def tearDown(self):
        state_module.init_state()

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
