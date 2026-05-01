#!/usr/bin/env python3
import os
import unittest
from unittest.mock import patch

from shared.python.config import env, env_bool, env_int


class TestConfig(unittest.TestCase):
    def test_env_returns_value_and_default(self):
        with patch.dict(os.environ, {"TEST_CONFIG_VALUE": "foo"}, clear=False):
            self.assertEqual(env("TEST_CONFIG_VALUE"), "foo")
            self.assertEqual(env("MISSING_VAR", "bar"), "bar")

    def test_env_bool_true_values(self):
        with patch.dict(
            os.environ, {"BOOL_TRUE": "true", "BOOL_TRUE_CAP": "True"}, clear=False
        ):
            self.assertTrue(env_bool("BOOL_TRUE"))
            self.assertTrue(env_bool("BOOL_TRUE_CAP"))

    def test_env_bool_false_values(self):
        with patch.dict(
            os.environ, {"BOOL_FALSE": "false", "BOOL_OTHER": "no"}, clear=False
        ):
            self.assertFalse(env_bool("BOOL_FALSE"))
            self.assertFalse(env_bool("BOOL_OTHER"))

    def test_env_int_parses_integer(self):
        with patch.dict(os.environ, {"INT_VALUE": "42"}, clear=False):
            self.assertEqual(env_int("INT_VALUE"), 42)

    def test_env_int_returns_default_when_empty(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(env_int("INT_NONE", 7), 7)

    def test_env_int_invalid_raises(self):
        import shared.python.logging_utils as logging_utils

        with patch.dict(os.environ, {"INT_BAD": "abc"}, clear=False):
            with patch.object(logging_utils, "fatal", side_effect=ValueError("bad")):
                with self.assertRaises(ValueError):
                    env_int("INT_BAD")
