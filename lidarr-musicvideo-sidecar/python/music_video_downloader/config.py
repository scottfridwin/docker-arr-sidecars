#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

"""Settings for the MusicVideoDownloader service, read from VIDEO_* environment variables."""

from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from pathlib import Path


def _env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def _env_int(name: str, default: int) -> int:
    value = _env(name)
    try:
        return int(value) if value else default
    except ValueError as exc:
        raise ValueError(f"Invalid integer for {name}: '{value}'") from exc


def _env_bool(name: str, default: bool) -> bool:
    value = _env(name)
    return value.lower() == "true" if value else default


def _env_list(name: str, default: str) -> list[str]:
    return [item.strip().lower() for item in _env(name, default).split(",") if item.strip()]


def parse_interval(value: str) -> float:
    """Parse '24h', '30m', '60s', '1d' (or 'none' / '0' for a single run) to seconds."""
    text = value.strip().lower()
    if text in ("none", "0", ""):
        return 0
    match = re.fullmatch(r"(\d+)([smhd])", text)
    if not match:
        raise ValueError(f"Invalid interval: '{value}'. Must be <number>[s|m|h|d] or 'none'")
    return int(match.group(1)) * {"s": 1, "m": 60, "h": 3600, "d": 86400}[match.group(2)]


# Uploads whose title contains any of these are not music videos (checked case-insensitively).
DEFAULT_EXCLUDE_KEYWORDS = (
    "lyric,lyrics,visualizer,visualiser,official audio,(audio),[audio],audio only,behind the scenes,making of,"
    "trailer,teaser,interview,q&a,reaction,karaoke,#shorts,commentary,track by track,documentary,rehearsal,"
    "snippet,preview,out now,acoustic,unplugged,sped up,slowed,instrumental,8d audio,dance practice,"
    "fan made,fanmade,vertical video,podcast,vevocertified,vevo certified,vevo lift,vevo dscvr,vevo presents,"
    "lip sync,grammys,grammy awards,saturday night live,tonight show,late show,late night with,jimmy kimmel,"
    "takeover"
)


# Whole words that disqualify an upload when they appear in a bracket group or a trailing " - ..." /
# " | ..." part of the title, e.g. "Song (Live at X)", "Song - Stripped Session", "Song [Vinyl Playback Video]".
DEFAULT_EXCLUDE_QUALIFIERS = (
    "live,audio,cover,episode,session,sessions,stripped,playback,tour,extras,news,announcement,podcast,"
    "trailer,teaser,lyrics,lyric,visualizer"
)


@dataclass
class Config:
    library_path: Path = field(default_factory=lambda: Path(_env("VIDEO_LIBRARY_PATH", "/music-videos")))
    state_dir: Path = field(default_factory=lambda: Path(_env("VIDEO_STATE_DIR", "/data")))
    work_dir: Path = field(default_factory=lambda: Path(_env("VIDEO_WORK_DIR", "/work")))
    interval: str = field(default_factory=lambda: _env("VIDEO_INTERVAL", "24h"))
    # Lidarr tag label that opts an artist in; empty = every monitored artist.
    artist_tag: str = field(default_factory=lambda: _env("VIDEO_ARTIST_TAG"))
    max_downloads_per_run: int = field(default_factory=lambda: _env_int("VIDEO_MAX_DOWNLOADS_PER_RUN", 10))
    artist_recheck_days: int = field(default_factory=lambda: _env_int("VIDEO_ARTIST_RECHECK_DAYS", 7))
    max_attempts: int = field(default_factory=lambda: _env_int("VIDEO_DOWNLOAD_ATTEMPT_THRESHOLD", 3))
    min_duration: int = field(default_factory=lambda: _env_int("VIDEO_MIN_DURATION", 90))
    max_duration: int = field(default_factory=lambda: _env_int("VIDEO_MAX_DURATION", 900))
    exclude_keywords: list[str] = field(
        default_factory=lambda: _env_list("VIDEO_EXCLUDE_KEYWORDS", DEFAULT_EXCLUDE_KEYWORDS)
    )
    exclude_qualifiers: list[str] = field(
        default_factory=lambda: _env_list("VIDEO_EXCLUDE_QUALIFIERS", DEFAULT_EXCLUDE_QUALIFIERS)
    )
    # yt-dlp format selector; the container is always MKV.
    format: str = field(default_factory=lambda: _env("VIDEO_FORMAT", "bv*+ba/b"))
    cookies_file: str = field(default_factory=lambda: _env("VIDEO_COOKIES_FILE"))
    dry_run: bool = field(default_factory=lambda: _env_bool("VIDEO_DRY_RUN", False))
    # Seconds to wait between downloads, to stay polite to YouTube.
    download_delay: int = field(default_factory=lambda: _env_int("VIDEO_DOWNLOAD_DELAY", 30))
    # Repair: bring videos already in the library up to the current naming, NFO and poster.
    repair: bool = field(default_factory=lambda: _env_bool("VIDEO_REPAIR", True))
    # YouTube metadata/thumbnail lookups the repair may make per run (videos it already knows need none).
    repair_max_per_run: int = field(default_factory=lambda: _env_int("VIDEO_REPAIR_MAX_PER_RUN", 100))
    repair_delay: int = field(default_factory=lambda: _env_int("VIDEO_REPAIR_DELAY", 5))

    @property
    def interval_seconds(self) -> float:
        return parse_interval(self.interval)

    @property
    def state_file(self) -> Path:
        return self.state_dir / "state.json"

    @property
    def cache_dir(self) -> Path:
        return self.state_dir / "cache"
