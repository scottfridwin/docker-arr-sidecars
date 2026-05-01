# SPDX-License-Identifier: GPL-3.0-only

import os
import re
import time
import traceback
from pathlib import Path

from shared.python.autoimport.common import create_download_client, scan_drop_directory
from shared.python.autoimport.strategy import ImportStrategy
from shared.python.arrapi import verify_arr_api_access
from shared.python.config import env
from shared.python.logging_utils import debug, error, fatal, info
from shared.python.state import init_state


def _parse_interval(value: str) -> float:
    if value is None or value == "":
        return 5.0
    value = value.strip()
    if re.match(r"^[0-9]+$", value):
        return float(value)
    match = re.match(r"^(?P<num>[0-9]+)(?P<unit>[smh])$", value, re.IGNORECASE)
    if not match:
        fatal(f"Invalid AUTOIMPORT_INTERVAL value: '{value}'")
    num = float(match.group("num"))
    unit = match.group("unit").lower()
    if unit == "s":
        return num
    if unit == "m":
        return num * 60
    if unit == "h":
        return num * 3600
    fatal(f"Invalid AUTOIMPORT_INTERVAL unit: '{unit}'")


def _validate_environment() -> None:
    missing = []
    if not env("AUTOIMPORT_GROUP"):
        missing.append("AUTOIMPORT_GROUP")
    for key in ["AUTOIMPORT_DROP_DIR", "AUTOIMPORT_SHARED_PATH", "AUTOIMPORT_WORK_DIR"]:
        value = env(key)
        if not value:
            missing.append(key)
        elif not Path(value).is_dir():
            fatal(f"{key} '{value}' does not exist")
    if missing:
        fatal(
            f"Missing required environment variables: {', '.join(sorted(set(missing)))}"
        )


def _log_startup() -> None:
    info(f"Starting AutoImport")
    debug(f"AUTOIMPORT_CACHE_HOURS={env('AUTOIMPORT_CACHE_HOURS')}")
    debug(f"AUTOIMPORT_DROP_DIR={env('AUTOIMPORT_DROP_DIR')}")
    debug(f"AUTOIMPORT_DOWNLOADCLIENT_NAME={env('AUTOIMPORT_DOWNLOADCLIENT_NAME')}")
    debug(f"AUTOIMPORT_GROUP={env('AUTOIMPORT_GROUP')}")
    debug(f"AUTOIMPORT_IMPORT_MARKER={env('AUTOIMPORT_IMPORT_MARKER')}")
    debug(f"AUTOIMPORT_INTERVAL={env('AUTOIMPORT_INTERVAL')}")
    debug(f"AUTOIMPORT_SHARED_PATH={env('AUTOIMPORT_SHARED_PATH')}")
    debug(f"AUTOIMPORT_WORK_DIR={env('AUTOIMPORT_WORK_DIR')}")
    debug(f"AUTOIMPORT_API_PAGE_SIZE={env('AUTOIMPORT_API_PAGE_SIZE', '100')}")
    debug(f"ARR_API_TIMEOUT={env('ARR_API_TIMEOUT', '60')}")


def main(strategy: ImportStrategy) -> None:
    try:
        _log_startup()
        _validate_environment()
        init_state()
        verify_arr_api_access()
        create_download_client()

        interval = _parse_interval(env("AUTOIMPORT_INTERVAL", "5m"))
        iteration = 0
        while True:
            iteration += 1
            debug(f"TRACE :: Starting scan iteration {iteration}")
            scan_drop_directory(strategy)
            debug(
                f"TRACE :: Scan iteration {iteration} complete; sleeping for {interval} seconds"
            )
            time.sleep(interval)
    except Exception as exc:
        error(f"Unhandled exception in AutoImport: {exc}")
        debug("TRACE :: " + traceback.format_exc())
        raise


if __name__ == "__main__":
    fatal("This module is not intended to be executed directly")
