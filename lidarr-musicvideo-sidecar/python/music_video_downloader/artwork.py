#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

"""Artist artwork for the music video library, copied from Lidarr.

Jellyfin shows each artist folder of a music video library as a plain folder and, without an image of its own,
uses a frame of one of the videos. Lidarr already has the artist's fanart.tv artwork, so each artist folder gets
folder.jpg (poster), backdrop.jpg (fanart), logo.png (clear logo) and banner.jpg, the names Jellyfin reads for a
folder. An image is downloaded again only when Lidarr's copy changes (its "lastWrite" stamp), recorded in
VIDEO_STATE_DIR/artwork.json.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from urllib.parse import urlsplit

from shared.python.arrapi import http_request
from shared.python.logging_utils import debug, info, warning
from shared.python.state import get_state

from . import library
from .config import Config

# Lidarr cover type -> file name Jellyfin reads for a folder's image of that kind.
ARTWORK_FILES = {
    "poster": "folder.jpg",
    "fanart": "backdrop.jpg",
    "clearlogo": "logo.png",
    "banner": "banner.jpg",
}


def _load(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def _save(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=1), encoding="utf-8")
    os.replace(tmp, path)


def fetch_cover(artist_id: int, url: str) -> bytes | None:
    """Download one of Lidarr's local covers ('/MediaCover/20/poster.jpg?lastWrite=...') through the API."""
    name = Path(urlsplit(url).path).name
    if not name:
        return None
    full = f"{get_state('arrUrl')}/api/{get_state('arrApiVersion')}/mediacover/artist/{artist_id}/{name}"
    status, body = http_request("GET", full)
    return body if status == 200 and body else None


def sync_artist(artist: dict, directory: Path, stamps: dict) -> int:
    """Write the artist's artwork into its folder; returns how many files were written."""
    written = 0
    for image in artist.get("images") or []:
        filename = ARTWORK_FILES.get(image.get("coverType"))
        url = image.get("url") or ""
        if not filename or not url.startswith("/MediaCover/"):
            continue
        target = directory / filename
        if target.is_file() and stamps.get(filename) == url:
            continue
        data = fetch_cover(artist["id"], url)
        if data is None:
            debug(f"{artist.get('artistName')}: Lidarr has no {image.get('coverType')} file yet")
            continue
        try:
            if not target.is_file() or target.read_bytes() != data:
                tmp = target.with_name(f".{target.name}.tmp")
                tmp.write_bytes(data)
                os.replace(tmp, target)
                written += 1
        finally:
            target.with_name(f".{target.name}.tmp").unlink(missing_ok=True)
        stamps[filename] = url
    return written


def run(artists: list[dict], cfg: Config) -> int:
    """Artwork for every selected artist whose folder holds videos. Runs after the repair, so videos have moved
    out of old-style folders first (artwork left there would keep an emptied old folder from being removed)."""
    stamps_file = cfg.state_dir / "artwork.json"
    stamps = _load(stamps_file)
    written = 0
    for artist in artists:
        directory = library.artist_dir(cfg.library_path, artist.get("artistName") or "Unknown")
        if not directory.is_dir() or not any(library.is_video(p) for p in directory.iterdir()):
            continue
        mbid = artist.get("foreignArtistId") or str(artist.get("id"))
        try:
            written += sync_artist(artist, directory, stamps.setdefault(mbid, {}))
        except OSError as exc:
            warning(f"{artist.get('artistName')}: artwork failed: {exc}")
    _save(stamps_file, stamps)
    if written:
        info(f"Artist artwork: {written} image(s) written")
    return written
