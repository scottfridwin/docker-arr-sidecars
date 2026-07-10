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


def manual_import_release(
    import_path: str,
    artist_id: int | str,
    album_id: int | str,
    release_id: int | str,
) -> tuple[bool, list[str]]:
    """Run a deterministic manual import by forcing artist/album/release for each file."""
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
    for item in results:
        if not isinstance(item, dict):
            continue
        path_val = item.get("path") or item.get("name") or "item"
        for rej in item.get("rejections", []) or []:
            reason = rej.get("reason") if isinstance(rej, dict) else str(rej)
            rejections.append(f"{path_val}: {reason}")

    return len(rejections) == 0, rejections


def get_wanted_albums(list_type: str, page: int = 1, page_size: int = 1000) -> dict:
    """
    Fetch a page of wanted albums from Lidarr.
    list_type: "missing" or "cutoff"
    Returns the full API response dict.
    """
    path = (
        f"wanted/{list_type}?page={page}&pagesize={page_size}"
        f"&sortKey=releaseDate&sortDirection=descending"
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

    Checks both missing and cutoff unmet lists.
    """
    album_ids: list[str] = []
    for list_type in ("missing", "cutoff"):
        arr_api_request("GET", f"wanted/{list_type}?page=1&pagesize=10000&sortKey=releaseDate&sortDirection=descending")
        response = get_state("arrApiResponse")
        try:
            data = json.loads(response) if isinstance(response, str) else response
        except (json.JSONDecodeError, TypeError):
            data = {}
        records = data.get("records", []) if isinstance(data, dict) else []
        album_ids.extend(
            str(r["id"]) for r in records
            if r.get("artist", {}).get("foreignArtistId") == foreign_artist_id
        )
    return album_ids
