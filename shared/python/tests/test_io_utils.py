#!/usr/bin/env python3
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from shared.python.io_utils import (
    load_json_text,
    parse_xml_config,
    read_json_file,
    xml_text,
)


class TestIOUtils(unittest.TestCase):
    def test_load_json_text_valid(self):
        self.assertEqual(load_json_text('{"a": 1}'), {"a": 1})

    def test_load_json_text_invalid_raises(self):
        with patch("shared.python.io_utils.fatal", side_effect=ValueError("bad json")):
            with self.assertRaises(ValueError):
                load_json_text("{invalid}")

    def test_read_json_file(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            file_path = Path(temp_dir) / "config.json"
            file_path.write_text('{"x": 2}', encoding="utf-8")
            self.assertEqual(read_json_file(str(file_path)), {"x": 2})

    def test_parse_xml_config_and_xml_text(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            xml_path = Path(temp_dir) / "config.xml"
            xml_path.write_text(
                "<Config><ApiKey>secret</ApiKey><UrlBase>/sonarr</UrlBase><Port>8989</Port></Config>",
                encoding="utf-8",
            )
            root = parse_xml_config(str(xml_path))
            self.assertEqual(xml_text(root, "Config", "ApiKey"), "secret")
            self.assertEqual(xml_text(root, "Config", "UrlBase"), "/sonarr")
            self.assertEqual(xml_text(root, "Config", "Port"), "8989")
