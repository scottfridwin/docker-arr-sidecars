#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

"""
Lidarr API interaction helpers specific to DeemixDownloader.

Wraps the shared arrapi module for Lidarr-specific operations:
- Fetching wanted albums (missing/cutoff)
- Adding download client
- Triggering album import scans
"""

from __future__ import annotations

import json
import os
import sys
import time
from urllib.parse import quote_plus
from typing import Any

# Add the app root so shared modules can be found
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "../..")))

from shared.python.arrapi import (
    arr_api_request,
    verify_arr_api_access,
)
from shared.python.state import get_state, init_state, set_state

from .config import cfg
from .logging import log


def add_download_client() -> None:
    """Add a Usenet Blackhole download client in Lidarr if it doesn't exist."""
    log.trace("Entering add_download_client")

    arr_api_request("GET", "downloadclient")
    response = get_state("arrApiResponse")

    try:
        clients = json.loads(response) if isinstance(response, str) else response
    except (json.JSONDecodeError, TypeError):
        clients = []

    # Check if already exists
    if isinstance(clients, list):
        for client in clients:
            if client.get("name") == cfg.download_client_name:
                log.debug(f"{cfg.download_client_name} download client already exists")
                return

    log.debug(f"{cfg.download_client_name} not found, creating...")

    payload = json.dumps({
        "enable": True,
        "protocol": "usenet",
        "priority": 10,
        "removeCompletedDownloads": True,
        "removeFailedDownloads": True,
        "name": cfg.download_client_name,
        "fields": [
            {"name": "nzbFolder", "value": str(cfg.shared_lidarr_path)},
            {"name": "watchFolder", "value": str(cfg.shared_lidarr_path)},
        ],
        "implementationName": "Usenet Blackhole",
        "implementation": "UsenetBlackhole",
        "configContract": "UsenetBlackholeSettings",
        "infoLink": "https://wiki.servarr.com/lidarr/supported#usenetblackhole",
        "tags": [],
    })

    arr_api_request("POST", "downloadclient", payload)
    log.debug(f"Successfully added {cfg.download_client_name} download client")


def notify_lidarr_import(import_path: str) -> None:
    """Trigger Lidarr's DownloadedAlbumsScan for a specific path."""
    payload = json.dumps({"name": "DownloadedAlbumsScan", "path": import_path})
    arr_api_request("POST", "command", payload)
    log.debug(f"Sent import notification to Lidarr for: {import_path}")


def _wait_for_command(command_id: int, timeout: int = 120, interval: float = 2.0) -> tuple[bool, list[str]]:
    """Poll a Lidarr command until it finishes; return (success, [message]) on failure/timeout."""
    waited = 0.0
    while waited < timeout:
        arr_api_request("GET", f"command/{command_id}")
        response = get_state("arrApiResponse")
        if isinstance(response, dict) and response.get("status") in ("completed", "failed"):
            if response.get("status") == "completed" and response.get("result") == "successful":
                return True, []
            return False, [response.get("message") or f"Manual import command did not succeed (status={response.get('status')}, result={response.get('result')})"]
        time.sleep(interval)
        waited += interval
    return False, ["Timed out waiting for manual import command to complete"]


def manual_import_release(
    import_path: str,
    artist_id: int | str,
    album_id: int | str,
    release_id: int | str,
) -> tuple[bool, list[str]]:
    """Run a deterministic manual import by forcing artist/album/release for each file.

    POST /manualimport only re-validates candidate items (recomputes rejections and
    track mapping against the forced release) - it does NOT move any files. The actual
    import only happens via the "ManualImport" command below, which needs the resolved
    per-file trackIds from that validation step.
    """
    folder = quote_plus(import_path)
    path = (
        f"manualimport?folder={folder}"
        f"&artistId={artist_id}"
        "&filterExistingFiles=false"
        "&replaceExistingFiles=true"
    )
    arr_api_request("GET", path)
    response = get_state("arrApiResponse")

    try:
        items = json.loads(response) if isinstance(response, str) else response
    except (json.JSONDecodeError, TypeError):
        items = []

    if not isinstance(items, list) or not items:
        return False, ["No manual import items returned by Lidarr"]

    updates: list[dict[str, Any]] = []
    for item in items:
        if not isinstance(item, dict):
            continue
        updates.append({
            "id": item.get("id"),
            "path": item.get("path", ""),
            "name": item.get("name", ""),
            "artistId": int(artist_id),
            "albumId": int(album_id),
            "albumReleaseId": int(release_id),
            "quality": item.get("quality"),
            "releaseGroup": item.get("releaseGroup", ""),
            "indexerFlags": item.get("indexerFlags", 0),
            "downloadId": item.get("downloadId", ""),
            "additionalFile": bool(item.get("additionalFile", False)),
            "replaceExistingFiles": True,
            "disableReleaseSwitching": True,
        })

    if not updates:
        return False, ["No valid manual import updates could be generated"]

    arr_api_request("POST", "manualimport", json.dumps(updates))
    post_response = get_state("arrApiResponse")
    try:
        results = json.loads(post_response) if isinstance(post_response, str) else post_response
    except (json.JSONDecodeError, TypeError):
        results = []

    if not isinstance(results, list):
        return False, ["Unexpected manual import response from Lidarr"]

    rejections: list[str] = []
    files: list[dict[str, Any]] = []
    for item in results:
        if not isinstance(item, dict):
            continue
        path_val = item.get("path") or item.get("name") or "item"
        item_rejections = item.get("rejections", []) or []
        for rej in item_rejections:
            reason = rej.get("reason") if isinstance(rej, dict) else str(rej)
            rejections.append(f"{path_val}: {reason}")
        if not item_rejections:
            files.append({
                "path": item.get("path", ""),
                "artistId": int(artist_id),
                "albumId": int(album_id),
                "albumReleaseId": int(release_id),
                "trackIds": [
                    t.get("id")
                    for t in item.get("tracks", []) or []
                    if isinstance(t, dict) and t.get("id")
                ],
                "quality": item.get("quality"),
                "releaseGroup": item.get("releaseGroup", ""),
                "indexerFlags": item.get("indexerFlags", 0),
                "downloadId": item.get("downloadId", ""),
                "disableReleaseSwitching": True,
            })

    if rejections:
        return False, rejections
    if not files:
        return False, ["No importable files after manual import validation"]

    # This command is the actual commit step; everything above was only a dry-run validation.
    arr_api_request(
        "POST",
        "command",
        json.dumps({
            "name": "ManualImport",
            "files": files,
            "importMode": "move",
            "replaceExistingFiles": True,
        }),
    )
    command_response = get_state("arrApiResponse")
    command_id = command_response.get("id") if isinstance(command_response, dict) else None
    if not command_id:
        return False, ["Manual import command was not accepted by Lidarr"]

    return _wait_for_command(command_id)



def get_wanted_albums(
    list_type: str, page: int = 1, page_size: int = 1000, include_artist: bool = False
) -> dict:
    """
    Fetch a page of wanted albums from Lidarr.
    list_type: "missing" or "cutoff"
    include_artist: Lidarr omits the nested "artist" object (foreignArtistId etc.)
    unless includeArtist=true is passed, since it defaults to false server-side.
    Returns the full API response dict.
    """
    path = (
        f"wanted/{list_type}?page={page}&pagesize={page_size}"
        f"&sortKey=releaseDate&sortDirection=descending"
        f"&includeArtist={'true' if include_artist else 'false'}"
    )
    arr_api_request("GET", path)
    response = get_state("arrApiResponse")
    try:
        return json.loads(response) if isinstance(response, str) else response
    except (json.JSONDecodeError, TypeError):
        return {"totalRecords": 0, "records": []}


def get_album_data(album_id: int | str) -> dict | None:
    """Fetch album data from Lidarr API."""
    arr_api_request("GET", f"album/{album_id}")
    response = get_state("arrApiResponse")
    try:
        data = json.loads(response) if isinstance(response, str) else response
        if isinstance(data, dict) and "artist" in data and "releases" in data:
            return data
    except (json.JSONDecodeError, TypeError):
        pass
    log.warning(f"Invalid album data for ID {album_id}")
    return None


def get_album_ids_by_release_group(foreign_album_id: str) -> list[str]:
    """Look up Lidarr album IDs by MusicBrainz release group ID (foreignAlbumId)."""
    arr_api_request("GET", f"album?foreignAlbumId={foreign_album_id}")
    response = get_state("arrApiResponse")
    try:
        albums = json.loads(response) if isinstance(response, str) else response
    except (json.JSONDecodeError, TypeError):
        albums = []
    if isinstance(albums, dict):
        # Single result returned as object
        albums = [albums] if "id" in albums else []
    if not isinstance(albums, list):
        return []
    return [str(a["id"]) for a in albums if a.get("id")]


def get_album_ids_by_artist(foreign_artist_id: str) -> list[str]:
    """Look up Lidarr album IDs for all wanted albums by a given MusicBrainz artist ID.

    Checks both missing and cutoff unmet lists, paginating like process_wanted_list
    so a large wanted list can't be pulled into memory in one huge response.
    """
    page_size = 1000
    album_ids: list[str] = []
    for list_type in ("missing", "cutoff"):
        page = 1
        total_pages = 1
        while page <= total_pages:
            response = get_wanted_albums(
                list_type, page=page, page_size=page_size, include_artist=True
            )
            total_records = response.get("totalRecords", 0) if isinstance(response, dict) else 0
            total_pages = max(1, (total_records + page_size - 1) // page_size)
            records = response.get("records", []) if isinstance(response, dict) else []
            album_ids.extend(
                str(r["id"]) for r in records
                if r.get("artist", {}).get("foreignArtistId") == foreign_artist_id
            )
            page += 1
    return album_ids
