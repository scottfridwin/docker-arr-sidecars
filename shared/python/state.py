#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

state = {}


def init_state() -> None:
    state.clear()


def get_state(key: str):
    return state.get(key, "")


def set_state(key: str, value) -> None:
    state[key] = value
