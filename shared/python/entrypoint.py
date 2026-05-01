#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR.parent.parent))

from shared.python.logging_utils import debug, error, info, warning

VALID_LOG_LEVELS = ("TRACE", "DEBUG", "INFO", "WARNING", "ERROR")


def set_healthy() -> None:
    try:
        Path("/tmp/health").write_text("healthy", encoding="utf-8")
    except OSError:
        warning("Failed to write healthy status file")


def set_unhealthy(exit_code: int = 1) -> None:
    try:
        Path("/tmp/health").write_text("unhealthy", encoding="utf-8")
    except OSError:
        warning("Failed to write unhealthy status file")
    sys.exit(exit_code)


def _validate_environment() -> None:
    log_level = os.environ.get("LOG_LEVEL", "INFO").upper()
    if log_level not in VALID_LOG_LEVELS:
        error(
            f"Invalid LOG_LEVEL value: '{log_level}'. Must be one of: {', '.join(VALID_LOG_LEVELS)}"
        )
        set_unhealthy()

    arr_config_path = os.environ.get("ARR_CONFIG_PATH")
    if not arr_config_path or not Path(arr_config_path).is_file():
        error(f"ARR_CONFIG_PATH '{arr_config_path}' does not exist")
        set_unhealthy()

    umask_value = os.environ.get("UMASK", "0002")
    if not re.fullmatch(r"[0-7]{3,4}", umask_value):
        error(f"UMASK value '{umask_value}' is invalid. Must be octal (e.g., 0022)")
        set_unhealthy()


def _apply_timezone() -> None:
    tz = os.environ.get("TZ")
    if not tz:
        return

    zoneinfo_path = Path("/usr/share/zoneinfo") / tz
    if zoneinfo_path.exists():
        os.environ["TZ"] = tz
        info(f"Timezone set to {tz}")
    else:
        warning(f"TZ='{tz}' not found in /usr/share/zoneinfo")


def _start_services() -> dict[int, subprocess.Popen]:
    service_dir = Path("/app/services")
    if not service_dir.is_dir():
        error(f"Service directory not found: {service_dir}")
        set_unhealthy()

    services = sorted(service_dir.glob("*.py"))
    if not services:
        error(f"No Python service files found in {service_dir}")
        set_unhealthy()

    processes: dict[int, subprocess.Popen] = {}
    for service in services:
        info(f"Starting service {service.name}")
        process = subprocess.Popen([sys.executable, str(service)])
        processes[process.pid] = process
        debug(f"Started PID {process.pid} for {service.name}")

    return processes


def _terminate_processes(processes: dict[int, subprocess.Popen]) -> None:
    for process in processes.values():
        if process.poll() is None:
            debug(f"Terminating PID {process.pid}")
            process.terminate()


def _wait_for_process_exit(processes: dict[int, subprocess.Popen]) -> None:
    try:
        while processes:
            pid, status = os.wait()
            process = processes.pop(pid, None)
            exit_code = status >> 8
            if process is not None:
                error(f"Service exited unexpectedly: PID {pid} code={exit_code}")
            else:
                error(f"Unknown child exited: PID {pid} code={exit_code}")
            _terminate_processes(processes)
            set_unhealthy(exit_code or 1)
    except KeyboardInterrupt:
        warning("Keyboard interrupt received; terminating services")
        _terminate_processes(processes)
        set_unhealthy(1)
    except ChildProcessError:
        error("All service processes exited")
        set_unhealthy(1)


def main() -> None:
    os.environ.setdefault("SCRIPT_NAME", "entrypoint")
    _apply_timezone()
    _validate_environment()
    set_healthy()

    umask_value = int(os.environ.get("UMASK", "0002"), 8)
    os.umask(umask_value)

    processes = _start_services()
    _wait_for_process_exit(processes)


if __name__ == "__main__":
    main()
