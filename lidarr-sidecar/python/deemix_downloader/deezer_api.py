#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

"""Deezer API client with caching, pagination, and retry logic."""

from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any

import requests

from .config import cfg
from .logging import log

_session: requests.Session | None = None


def _get_session() -> requests.Session:
    global _session
    if _session is None:
        _session = requests.Session()
        _session.headers.update(
            {"User-Agent": "Mozilla/5.0 (compatible; deemix-sidecar/1.0)"}
        )
    return _session


def call_deezer_api(url: str) -> dict | list | None:
    """
    Call Deezer API with retries.
    Returns parsed JSON on success, None on failure.
    """
    max_retries = cfg.deezer_api_retries
    timeout = cfg.deezer_api_timeout

    for attempt in range(1, max_retries + 1):
        log.debug(f"Calling Deezer API: {url}")
        try:
            resp = _get_session().get(url, timeout=timeout)
            if resp.status_code == 200:
                data = resp.json()
                # Check for API-level errors
                if isinstance(data, dict) and "error" in data:
                    err = data["error"]
                    if err:
                        log.warning(f"Deezer API error for {url}: {err}")
                        return None
                return data
            else:
                log.warning(
                    f"Deezer API returned HTTP {resp.status_code} for {url}, "
                    f"retrying ({attempt}/{max_retries})..."
                )
        except (requests.RequestException, ValueError) as e:
            log.warning(
                f"Deezer API request failed for {url}: {e}, "
                f"retrying ({attempt}/{max_retries})..."
            )
        time.sleep(1)

    log.warning(f"Failed to get valid response from Deezer API after {max_retries} attempts for {url}")
    return None


def get_deezer_album_info(album_id: str | int) -> dict | None:
    """
    Fetch full Deezer album info (with all tracks) using cache.
    Returns album JSON dict or None on failure.
    """
    album_id = str(album_id)
    cache_file = cfg.cache_dir / f"deezer-album-{album_id}.json"

    # Try cache
    if cache_file.is_file():
        try:
            data = json.loads(cache_file.read_text(encoding="utf-8"))
            if isinstance(data, dict) and "id" in data:
                log.debug(f"Using cached Deezer album data for {album_id}")
                return data
        except (json.JSONDecodeError, OSError):
            log.warning(f"Cached album JSON invalid, refetching: {cache_file}")

    # Fetch from API
    data = call_deezer_api(f"https://api.deezer.com/album/{album_id}")
    if data is None:
        log.error(f"Failed to get album info for {album_id}")
        return None

    if not isinstance(data, dict):
        return None

    # Check for error response
    if "error" in data and data["error"]:
        log.warning(f"Deezer API returned error for album {album_id}: {data['error']}")
        return None

    # Handle album ID remapping
    actual_id = str(data.get("id", album_id))
    if actual_id != album_id:
        log.debug(f"Deezer album ID {album_id} remapped to {actual_id}")

    # Handle track pagination if needed
    nb_tracks = data.get("nb_tracks", 0)
    embedded_tracks = data.get("tracks", {}).get("data", [])

    if len(embedded_tracks) < nb_tracks:
        log.debug(f"Album {actual_id} has {nb_tracks} tracks, fetching remaining pages")
        all_tracks = []
        next_url: str | None = f"https://api.deezer.com/album/{actual_id}/tracks"

        while next_url:
            page = call_deezer_api(next_url)
            if page is None:
                log.error("Failed fetching Deezer album tracks")
                return None

            page_tracks = page.get("data", [])
            all_tracks.extend(page_tracks)
            next_url = page.get("next")
            if next_url:
                time.sleep(0.2)

        data["tracks"] = {"data": all_tracks, "total": len(all_tracks)}

    # Write cache
    try:
        cache_file.parent.mkdir(parents=True, exist_ok=True)
        cache_file.write_text(json.dumps(data), encoding="utf-8")
    except OSError as e:
        log.warning(f"Failed to write cache: {e}")

    return data
