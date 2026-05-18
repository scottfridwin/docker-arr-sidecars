#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

"""MusicBrainz API client with caching and rate-limit handling."""

from __future__ import annotations

import json
import time
from pathlib import Path

import requests

from .config import cfg
from .logging import log

MB_USER_AGENT = "docker-arr-sidecars/1.0.0 (https://github.com/scottfridwin/docker-arr-sidecars)"

_session: requests.Session | None = None
_last_request_time: float = 0.0
_MIN_REQUEST_INTERVAL: float = 1.1  # MusicBrainz rate limit: 1 req/sec


def _get_session() -> requests.Session:
    global _session
    if _session is None:
        _session = requests.Session()
        _session.headers.update({
            "User-Agent": MB_USER_AGENT,
            "Accept": "application/json",
        })
    return _session


def call_musicbrainz_api(url: str) -> dict | None:
    """
    Call MusicBrainz API with exponential backoff and rate-limit handling.
    Returns parsed JSON or None.
    """
    global _last_request_time
    max_attempts = 10
    backoff = 5

    # Proactive rate-limit: wait at least 1.1s between requests
    elapsed = time.time() - _last_request_time
    if elapsed < _MIN_REQUEST_INTERVAL:
        time.sleep(_MIN_REQUEST_INTERVAL - elapsed)

    for attempt in range(1, max_attempts + 1):
        _last_request_time = time.time()
        log.debug(f"Calling MusicBrainz API ({attempt}/{max_attempts}): {url}")
        try:
            resp = _get_session().get(url, timeout=15, allow_redirects=True)

            if resp.status_code == 200:
                try:
                    return resp.json()
                except ValueError:
                    log.warning("Invalid JSON from MusicBrainz, retrying...")
            elif resp.status_code in (429, 503):
                log.warning(f"HTTP {resp.status_code} from MusicBrainz, backing off {backoff}s...")
                time.sleep(backoff)
                backoff *= 2
                continue
            elif resp.status_code >= 500:
                log.warning(f"Server error {resp.status_code}, retrying...")
                time.sleep(backoff)
                backoff *= 2
                continue
            else:
                log.warning(f"Unexpected HTTP {resp.status_code} from MusicBrainz")
                return None

        except requests.RequestException as e:
            log.warning(f"MusicBrainz request failed: {e}, retrying...")
            time.sleep(backoff)
            backoff *= 2

    log.error(f"CallMusicBrainzAPI failed after {max_attempts} attempts")
    return None


def fetch_musicbrainz_release(mbid: str) -> dict | None:
    """
    Fetch MusicBrainz release info with caching.
    Includes recordings and url-rels.
    """
    if not mbid or mbid == "null":
        return None

    cache_file = cfg.cache_dir / f"mb-release-{mbid}.json"

    # Try cache
    if cache_file.is_file():
        try:
            data = json.loads(cache_file.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                log.debug(f"Using cached MB release for {mbid}")
                return data
        except (json.JSONDecodeError, OSError):
            pass

    url = f"https://musicbrainz.org/ws/2/release/{mbid}?fmt=json&inc=recordings+url-rels"
    data = call_musicbrainz_api(url)

    if data is not None:
        try:
            cache_file.parent.mkdir(parents=True, exist_ok=True)
            cache_file.write_text(json.dumps(data), encoding="utf-8")
        except OSError:
            pass

    return data
