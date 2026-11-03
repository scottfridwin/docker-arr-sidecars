#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

"""Official YouTube channels of an artist, from the artist's MusicBrainz URL relationships."""

from __future__ import annotations

import json
import re
import time
from pathlib import Path

import requests

from shared.python.logging_utils import debug, warning

MB_USER_AGENT = "docker-arr-sidecars/1.0.0 (https://github.com/scottfridwin/docker-arr-sidecars)"
# MusicBrainz allows one request per second.
_MIN_INTERVAL = 1.1
_last_request = 0.0
# "youtube" is the artist's channel; "youtube music" points at YouTube Music, not at video uploads.
_CHANNEL_REL_TYPES = {"youtube", "video channel"}
_CHANNEL_URL = re.compile(r"^https?://(?:www\.|m\.)?youtube\.com/(channel/[\w-]+|user/[\w.-]+|c/[^/?#]+|@[^/?#]+)")


def _get(url: str) -> dict | None:
    global _last_request
    backoff = 5
    for attempt in range(1, 6):
        wait = _MIN_INTERVAL - (time.time() - _last_request)
        if wait > 0:
            time.sleep(wait)
        _last_request = time.time()
        try:
            resp = requests.get(url, headers={"User-Agent": MB_USER_AGENT, "Accept": "application/json"}, timeout=20)
        except requests.RequestException as exc:
            warning(f"MusicBrainz request failed ({attempt}/5): {exc}")
        else:
            if resp.status_code == 200:
                return resp.json()
            if resp.status_code == 404:
                return None
            warning(f"MusicBrainz HTTP {resp.status_code} ({attempt}/5) for {url}")
        time.sleep(backoff)
        backoff *= 2
    return None


def channel_urls(relations: list[dict]) -> list[str]:
    """YouTube channel URLs ('https://www.youtube.com/channel/UC...') from MusicBrainz url-rels."""
    urls: list[str] = []
    for rel in relations or []:
        if rel.get("type") not in _CHANNEL_REL_TYPES or rel.get("ended"):
            continue
        match = _CHANNEL_URL.match(str(rel.get("url", {}).get("resource", "")))
        if match:
            url = f"https://www.youtube.com/{match.group(1)}"
            if url not in urls:
                urls.append(url)
    return urls


def artist_channels(mbid: str, cache_dir: Path, max_age_days: int = 30) -> list[str]:
    cache_file = cache_dir / f"mb-artist-{mbid}.json"
    data = None
    if cache_file.is_file() and time.time() - cache_file.stat().st_mtime < max_age_days * 86400:
        try:
            data = json.loads(cache_file.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            data = None
    if data is None:
        data = _get(f"https://musicbrainz.org/ws/2/artist/{mbid}?inc=url-rels&fmt=json")
        if data is None:
            return []
        cache_dir.mkdir(parents=True, exist_ok=True)
        cache_file.write_text(json.dumps(data), encoding="utf-8")
    urls = channel_urls(data.get("relations", []))
    debug(f"MusicBrainz artist {mbid}: {len(urls)} YouTube channel(s)")
    return urls
