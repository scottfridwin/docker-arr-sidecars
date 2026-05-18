#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

"""Logging utilities for the DeemixDownloader service."""

from __future__ import annotations

import os
import sys


class _Logger:
    """Simple logger matching the sidecar logging pattern."""

    LEVELS = {"TRACE": 0, "DEBUG": 1, "INFO": 2, "WARNING": 3, "ERROR": 4}

    def __init__(self):
        self._level = self.LEVELS.get(
            os.environ.get("LOG_LEVEL", "INFO").upper(), 2
        )
        self._script_name = "DeemixDownloader"

    def _log(self, level: str, msg: str) -> None:
        if self.LEVELS.get(level, 2) >= self._level:
            print(f"{self._script_name} :: {level} :: {msg}", flush=True)

    def trace(self, msg: str) -> None:
        self._log("TRACE", msg)

    def debug(self, msg: str) -> None:
        self._log("DEBUG", msg)

    def info(self, msg: str) -> None:
        self._log("INFO", msg)

    def warning(self, msg: str) -> None:
        self._log("WARNING", msg)

    def error(self, msg: str) -> None:
        self._log("ERROR", msg)

    def fatal(self, msg: str) -> None:
        self._log("ERROR", msg)
        sys.exit(1)


log = _Logger()
