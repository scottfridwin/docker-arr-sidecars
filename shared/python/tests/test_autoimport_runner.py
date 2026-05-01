#!/usr/bin/env python3
import unittest

from shared.python.autoimport.runner import _parse_interval


class TestAutoImportRunner(unittest.TestCase):
    def test_parse_interval_default(self):
        self.assertEqual(_parse_interval(""), 5.0)
        self.assertEqual(_parse_interval(None), 5.0)

    def test_parse_interval_seconds(self):
        self.assertEqual(_parse_interval("10s"), 10.0)

    def test_parse_interval_minutes(self):
        self.assertEqual(_parse_interval("2m"), 120.0)

    def test_parse_interval_hours(self):
        self.assertEqual(_parse_interval("1h"), 3600.0)

    def test_parse_interval_invalid_raises(self):
        with self.assertRaises(SystemExit):
            _parse_interval("bad")
