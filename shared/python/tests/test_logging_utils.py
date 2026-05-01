#!/usr/bin/env python3
import io
import unittest
from unittest.mock import patch

import shared.python.logging_utils as logging_utils


class TestLoggingUtils(unittest.TestCase):
    def test_log_respects_log_level(self):
        with patch.object(logging_utils, "LOG_LEVEL", "INFO"):
            fake_stderr = io.StringIO()
            with patch("sys.stderr", fake_stderr):
                logging_utils.debug("hidden")
                logging_utils.info("visible")
            output = fake_stderr.getvalue()
            self.assertIn("INFO :: visible", output)
            self.assertNotIn("DEBUG :: hidden", output)

    def test_fatal_exits(self):
        fake_stderr = io.StringIO()
        with patch("sys.stderr", fake_stderr):
            with self.assertRaises(SystemExit):
                logging_utils.fatal("boom")
        self.assertIn("ERROR :: boom", fake_stderr.getvalue())
