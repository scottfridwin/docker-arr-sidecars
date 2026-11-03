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

    def test_trace_is_hidden_at_debug_level(self):
        with patch.object(logging_utils, "LOG_LEVEL", "DEBUG"):
            fake_stderr = io.StringIO()
            with patch("sys.stderr", fake_stderr):
                logging_utils.trace("trace detail")
                logging_utils.debug("debug detail")
            output = fake_stderr.getvalue()
            self.assertIn("DEBUG :: debug detail", output)
            self.assertNotIn("TRACE :: trace detail", output)

    def test_trace_is_shown_at_trace_level(self):
        with patch.object(logging_utils, "LOG_LEVEL", "TRACE"):
            fake_stderr = io.StringIO()
            with patch("sys.stderr", fake_stderr):
                logging_utils.trace("trace detail")
            self.assertIn("TRACE :: trace detail", fake_stderr.getvalue())

    def test_fatal_exits(self):
        fake_stderr = io.StringIO()
        with patch("sys.stderr", fake_stderr), self.assertRaises(SystemExit):
            logging_utils.fatal("boom")
        self.assertIn("ERROR :: boom", fake_stderr.getvalue())
