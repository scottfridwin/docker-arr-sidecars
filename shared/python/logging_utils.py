#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

import os
import sys

SCRIPT_NAME = os.environ.get("SCRIPT_NAME", "python")
LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO").upper()
LOG_PRIORITY = {"TRACE": 5, "DEBUG": 10, "INFO": 20, "WARNING": 30, "ERROR": 40}


def log(level: str, message: str) -> None:
    if LOG_PRIORITY.get(level, 100) >= LOG_PRIORITY.get(LOG_LEVEL, 20):
        print(f"{SCRIPT_NAME} :: {level} :: {message}", file=sys.stderr)


def debug(message: str) -> None:
    log("DEBUG", message)


def info(message: str) -> None:
    log("INFO", message)


def warning(message: str) -> None:
    log("WARNING", message)


def error(message: str) -> None:
    log("ERROR", message)


def fatal(message: str) -> None:
    error(message)
    sys.exit(1)
