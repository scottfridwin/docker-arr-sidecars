#!/usr/bin/env python3
import re
import unittest

from shared.python.autoimport.strategy import radarr_strategy, sonarr_strategy


class TestAutoImportStrategy(unittest.TestCase):
    def test_sonarr_strategy_payload_contains_title_and_timestamp(self):
        payload = sonarr_strategy().push_release_payload("MySeries")
        self.assertIn('"title":"MySeries"', payload)
        self.assertRegex(
            payload, r'"publishDate":"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"'
        )

    def test_radarr_strategy_payload_is_valid_json_string(self):
        payload = radarr_strategy().notify_payload("/tmp/import")
        self.assertIn('"DownloadedMoviesScan"', payload)
        self.assertIn('"path":"/tmp/import"', payload)
