#!/usr/bin/env python3
import unittest

from shared.python.state import get_state, init_state, set_state


class TestState(unittest.TestCase):
    def tearDown(self):
        init_state()

    def test_state_roundtrip(self):
        init_state()
        set_state("key", "value")
        self.assertEqual(get_state("key"), "value")

    def test_state_clear(self):
        init_state()
        set_state("a", "b")
        init_state()
        self.assertEqual(get_state("a"), "")
