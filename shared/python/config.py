#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

import os


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


def env_bool(name: str, default: bool = False) -> bool:
    value = env(name, str(default)).strip().lower()
    return value == "true"


def env_int(name: str, default: int = 0) -> int:
    value = env(name, "").strip()
    if not value:
        return default
    try:
        return int(value)
    except ValueError:
        from .logging_utils import fatal

        fatal(f"Invalid integer for {name}: '{value}'")
