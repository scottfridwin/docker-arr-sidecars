# SPDX-License-Identifier: GPL-3.0-only

import json
import os
import stat
import time
from pathlib import Path
from shutil import move

from shared.python.arrapi import arr_api_request
from shared.python.config import env
from shared.python.logging_utils import debug, error, fatal, info, warning
from shared.python.state import get_state, set_state


def _cache_path(filename: str) -> Path:
    return Path(env("AUTOIMPORT_WORK_DIR")) / filename


def _write_atomic(path: Path, text: str) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(path)


def _load_cached_paths(cache_file: Path) -> list[str]:
    if not cache_file.exists():
        return []
    return [
        line for line in cache_file.read_text(encoding="utf-8").splitlines() if line
    ]


def _save_cached_paths(cache_file: Path, paths: list[str]) -> None:
    _write_atomic(cache_file, "\n".join(paths) + ("\n" if paths else ""))


def _resource_paths(strategy) -> list[str]:
    cache_file = _cache_path(strategy.cache_filename)
    if cache_file.exists():
        debug(f"Loading cached paths from {cache_file}")
        return _load_cached_paths(cache_file)

    debug(f"{strategy.cache_filename} cache not found, refreshing...")
    return _refresh_resource_cache(strategy, cache_file)


def _fetch_paginated_resource_paths(strategy, cache_file: Path) -> list[str]:
    page_size = int(env("AUTOIMPORT_API_PAGE_SIZE", "100"))
    page = 1
    resource_paths: list[str] = []
    debug(
        f"TRACE :: Fetching paginated {strategy.resource_endpoint} (pageSize={page_size})"
    )

    while True:
        query = f"{strategy.resource_endpoint}?page={page}&pageSize={page_size}"
        debug(f"TRACE :: Requesting page {page} for {strategy.resource_endpoint}")
        try:
            arr_api_request("GET", query)
        except SystemExit:
            if page == 1:
                debug(
                    "TRACE :: Pagination unavailable or failed; falling back to unpaged resource fetch"
                )
                return _fetch_unpaged_resource_paths(strategy, cache_file)
            fatal(f"Failed to paginate {strategy.resource_endpoint} after page {page}")

        response = get_state("arrApiResponse")
        if not isinstance(response, list):
            fatal(f"Failed to fetch resource list from {env('ARR_NAME')} API")

        if not response:
            debug(f"TRACE :: Page {page} returned no results")
            break

        debug(f"TRACE :: Page {page} returned {len(response)} results")
        resource_paths.extend(
            item.get("path")
            for item in response
            if isinstance(item, dict) and item.get("path")
        )
        if len(response) < page_size:
            break
        page += 1

    _save_cached_paths(cache_file, [str(path) for path in resource_paths])
    info(
        f"{strategy.resource_endpoint.capitalize()} cache refreshed with {len(resource_paths)} entries"
    )
    return resource_paths


def _fetch_unpaged_resource_paths(strategy, cache_file: Path) -> list[str]:
    arr_api_request("GET", strategy.resource_endpoint)
    response = get_state("arrApiResponse")
    if not isinstance(response, list):
        fatal(f"Failed to fetch resource list from {env('ARR_NAME')} API")

    resource_paths = [
        item.get("path")
        for item in response
        if isinstance(item, dict) and item.get("path")
    ]
    _save_cached_paths(cache_file, [str(path) for path in resource_paths])
    info(
        f"{strategy.resource_endpoint.capitalize()} cache refreshed with {len(resource_paths)} entries"
    )
    return resource_paths


def _refresh_resource_cache(strategy, cache_file: Path) -> list[str]:
    return _fetch_paginated_resource_paths(strategy, cache_file)


def create_download_client() -> None:
    download_client_name = env("AUTOIMPORT_DOWNLOADCLIENT_NAME")
    shared_path = env("AUTOIMPORT_SHARED_PATH")

    debug("TRACE :: Entering create_download_client...")
    arr_api_request("GET", "downloadclient")
    response = get_state("arrApiResponse")

    if not isinstance(response, list):
        fatal("Invalid downloadclient response from ARR API")

    if any(
        client.get("name") == download_client_name
        for client in response
        if isinstance(client, dict)
    ):
        info(
            f"{download_client_name} download client already exists, skipping creation."
        )
        debug("TRACE :: Exiting create_download_client...")
        return

    info(f"{download_client_name} client not found, creating it...")
    payload = {
        "enable": True,
        "protocol": "usenet",
        "priority": 10,
        "removeCompletedDownloads": True,
        "removeFailedDownloads": True,
        "name": download_client_name,
        "fields": [
            {"name": "nzbFolder", "value": shared_path},
            {"name": "watchFolder", "value": shared_path},
        ],
        "implementationName": "Usenet Blackhole",
        "implementation": "UsenetBlackhole",
        "configContract": "UsenetBlackholeSettings",
        "infoLink": "https://wiki.servarr.com/lidarr/supported#usenetblackhole",
        "tags": [],
    }
    arr_api_request("POST", "downloadclient", json.dumps(payload))
    info(f"Successfully added {download_client_name} download client.")
    debug("TRACE :: Exiting create_download_client...")


def _permission_issues(path: Path) -> tuple[bool, str]:
    bad_files = []
    for item in path.rglob("*"):
        if item == path or item.is_symlink():
            continue
        try:
            item_stat = item.stat()
        except OSError:
            continue

        mode = stat.filemode(item_stat.st_mode)
        group = str(item_stat.st_gid)
        group_perms = mode[4:7]
        issue = []

        if group != env("AUTOIMPORT_GROUP"):
            issue.append(f"wrong group ({group}, expected {env('AUTOIMPORT_GROUP')})")
        if "r" not in group_perms or "w" not in group_perms:
            issue.append("missing group rw perms")

        if issue:
            entry = f"{item} :: {', '.join(issue)}"
            bad_files.append(entry)
            warning(entry)

    if bad_files:
        return False, "\n".join(bad_files)
    return True, ""


def check_permissions(path: str) -> bool:
    debug("TRACE :: Entering check_permissions...")
    root_path = Path(path)
    ok, report = _permission_issues(root_path)
    if ok:
        debug(
            f"DEBUG :: All files in {root_path} have correct group and group rw permissions"
        )
        set_state("permissionIssues", "")
    else:
        warning(f"Permission/group check failed for {root_path}")
        set_state("permissionIssues", report)
    debug("TRACE :: Exiting check_permissions...")
    return ok


def _write_status(import_dir: Path, text: str) -> None:
    status_file = import_dir / "IMPORT_STATUS.txt"
    status_file.write_text(text, encoding="utf-8")


def _move_directory(source: Path, destination: Path) -> None:
    if destination.exists():
        fatal(f"Destination already exists: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    move(str(source), str(destination))


def get_import_target_name(import_dir: str) -> str:
    marker = env("AUTOIMPORT_IMPORT_MARKER")
    name = Path(import_dir).name
    target = name[len(marker) :] if name.startswith(marker) else name
    return target.lstrip()


def ensure_resource_paths(strategy) -> list[str]:
    cache_file = _cache_path(strategy.cache_filename)
    cache_hours = int(env("AUTOIMPORT_CACHE_HOURS", "1"))
    if not cache_file.exists():
        debug(f"{strategy.cache_filename} cache not found, refreshing...")
        return _refresh_resource_cache(strategy, cache_file)

    current_time = os.path.getmtime(cache_file)
    age = time.time() - current_time
    if age > cache_hours * 3600:
        debug(
            f"DEBUG :: {strategy.cache_filename} cache older than {cache_hours}h, refreshing..."
        )
        return _refresh_resource_cache(strategy, cache_file)

    return _load_cached_paths(cache_file)


def _find_match(target_name: str, paths: list[str]) -> str | None:
    needle = f"/{target_name}"
    for path in paths:
        if needle in path:
            return path
    return None


def process_import(import_dir: str, strategy) -> None:
    debug("TRACE :: Entering process_import...")
    target_name = get_import_target_name(import_dir)
    info(f"Processing flagged import folder: {Path(import_dir).name}")

    paths = ensure_resource_paths(strategy)
    match_path = _find_match(target_name, paths)

    if match_path:
        debug(f"Match found: {target_name} -> {match_path}")
        if not check_permissions(import_dir):
            issues = get_state("permissionIssues")
            _write_status(
                Path(import_dir), f"Permission or ownership issues detected:\n{issues}"
            )
        else:
            dest_dir = Path(env("AUTOIMPORT_SHARED_PATH")) / target_name
            debug(f"Moving '{import_dir}' to '{dest_dir}'")
            _move_directory(Path(import_dir), dest_dir)
            debug(
                "DEBUG :: No notification behavior configured; import move is complete"
            )
    else:
        debug(f"No match found for '{target_name}'")
        _write_status(
            Path(import_dir),
            f"No matching {env('ARR_NAME')} directory found for '{target_name}'.",
        )
        new_dir = Path(env("AUTOIMPORT_DROP_DIR")) / target_name
        _move_directory(Path(import_dir), new_dir)
        debug(f"Removed import tag from '{import_dir}'")

    debug("TRACE :: Exiting process_import...")


def scan_drop_directory(strategy) -> None:
    info(
        f"Scanning {env('AUTOIMPORT_DROP_DIR')} for directories marked with '{env('AUTOIMPORT_IMPORT_MARKER')}'"
    )
    drop_dir = Path(env("AUTOIMPORT_DROP_DIR"))
    marker = env("AUTOIMPORT_IMPORT_MARKER")
    entries = sorted(drop_dir.iterdir())
    debug(f"TRACE :: Found {len(entries)} entries in drop directory")
    for entry in entries:
        if entry.is_dir() and entry.name.startswith(marker):
            debug(f"TRACE :: Found candidate import folder: {entry.name}")
            process_import(str(entry), strategy)
    info("Scan complete")
