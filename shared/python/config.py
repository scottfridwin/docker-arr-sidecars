#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

import os
from pathlib import Path


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


def env_or_file(name: str) -> str:
    value = env(name)
    file_name = f"{name}_FILE"
    file_path = env(file_name)
    if value and file_path:
        raise ValueError(f"Set either {name} or {file_name}, not both")
    if not file_path:
        return value
    try:
        return Path(file_path).read_text(encoding="utf-8").rstrip("\r\n")
    except (OSError, UnicodeError):
        raise ValueError(f"Could not read {file_name} as UTF-8") from None


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
