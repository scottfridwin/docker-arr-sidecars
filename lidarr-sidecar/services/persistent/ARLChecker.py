#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

"""Lidarr ARLChecker persistent service.

Validates the Deezer ARL token file on an interval:
- File must exist, be owned by current user, and have mode 0600
- Token is validated against the Deezer API
"""

import os
import re
import stat
import sys
import time

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "../..")))
os.environ.setdefault("SCRIPT_NAME", "ARLChecker")

from shared.python.config import env
from shared.python.logging_utils import debug, error, info, fatal


def _parse_interval(value: str) -> float:
    """Parse interval string like '24h', '30m', '60s', '1d' to seconds."""
    if not value:
        fatal("ARLUPDATE_INTERVAL is not set")
    match = re.fullmatch(r"(\d+)([smhd])", value.strip())
    if not match:
        fatal(
            f"ARLUPDATE_INTERVAL is invalid ('{value}'). Must be <number>[s|m|h|d]"
        )
    num = int(match.group(1))
    unit = match.group(2)
    multipliers = {"s": 1, "m": 60, "h": 3600, "d": 86400}
    return num * multipliers[unit]


def _validate_arl_file(path: str) -> None:
    """Validate ARL file exists, ownership, and permissions."""
    if not os.path.isfile(path):
        fatal(f"ARL file not found at '{path}'")

    file_stat = os.stat(path)
    current_uid = os.getuid()

    if file_stat.st_uid != current_uid:
        fatal(
            f"ARL file '{path}' is not owned by the current user (uid {current_uid})"
        )

    perms = stat.S_IMODE(file_stat.st_mode)
    if perms != 0o600:
        fatal(
            f"ARL file '{path}' has incorrect permissions ({oct(perms)}). Expected 0600."
        )


def _check_token(arl_file: str) -> bool:
    """Read and validate the ARL token via Deezer API."""
    from requests import Session

    with open(arl_file, "r", encoding="utf-8") as f:
        token = f.read().strip().strip('"')

    if not token:
        error("ARL token file is empty")
        return False

    user_agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:83.0) Gecko/20100101 Firefox/110.0"
    session = Session()
    session.headers.update({"User-Agent": user_agent})

    try:
        res = session.post(
            "http://www.deezer.com/ajax/gw-light.php",
            cookies={"arl": token},
            data={
                "api_token": "null",
                "api_version": "1.0",
                "input": "3",
                "method": "deezer.getUserData",
            },
        )
        res.raise_for_status()
        data = res.json()
    except Exception as e:
        error(f"Error connecting to Deezer: {e}")
        return False

    if "error" in data and data["error"]:
        error(f"Deezer API returned error: {data['error']}")
        return False

    user_id = data.get("results", {}).get("USER", {}).get("USER_ID", 0)
    if user_id == 0:
        error("ARL token invalid or expired")
        return False

    info("ARL token is valid")
    return True


def main() -> None:
    info("Starting ARLChecker")

    interval_str = env("ARLUPDATE_INTERVAL", "24h")
    arl_file = env("AUDIO_DEEMIX_ARL_FILE", "/deemix_arl_token")

    debug(f"ARLUPDATE_INTERVAL={interval_str}")
    debug(f"AUDIO_DEEMIX_ARL_FILE={arl_file}")

    interval_seconds = _parse_interval(interval_str)

    # Validate file ownership/permissions once at startup
    _validate_arl_file(arl_file)

    while True:
        info("Running ARL Token Check...")
        if not _check_token(arl_file):
            fatal("ARL token check failed")

        info(f"ARL Token Check Complete. Sleeping for {interval_str}.")
        time.sleep(interval_seconds)


if __name__ == "__main__":
    main()
