#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

"""Configuration container for the DeemixDownloader service."""

from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from pathlib import Path


def _env(key: str, default: str = "") -> str:
    return os.environ.get(key, default)


def _env_bool(key: str, default: bool = False) -> bool:
    val = _env(key, str(default)).strip().lower()
    return val in ("true", "1", "yes")


def _env_int(key: str, default: int = 0) -> int:
    try:
        return int(_env(key, str(default)))
    except ValueError:
        return default


def _parse_interval(value: str) -> float:
    """Parse interval string (e.g., '15m', '1h', '30s', 'none') to seconds."""
    if not value or value.strip().lower() == "none":
        return 0.0
    value = value.strip()
    if value.isdigit():
        return float(value)
    m = re.match(r"^(\d+)([smhd])$", value, re.IGNORECASE)
    if not m:
        raise ValueError(f"Invalid interval: {value}")
    num = int(m.group(1))
    unit = m.group(2).lower()
    return num * {"s": 1, "m": 60, "h": 3600, "d": 86400}[unit]


@dataclass
class Config:
    """All configuration for the DeemixDownloader, loaded from environment."""

    # Paths
    work_path: Path = field(default_factory=lambda: Path(_env("AUDIO_WORK_PATH", "/work")))
    data_path: Path = field(default_factory=lambda: Path(_env("AUDIO_DATA_PATH", "/data")))
    shared_lidarr_path: Path = field(default_factory=lambda: Path(_env("AUDIO_SHARED_LIDARR_PATH", "/sidecar-import")))
    deemix_arl_file: Path = field(default_factory=lambda: Path(_env("AUDIO_DEEMIX_ARL_FILE", "/deemix_arl_token")))
    priority_file: str = field(default_factory=lambda: _env("AUDIO_PRIORITY_FILE", ""))

    # Quality / download settings
    apply_beets: bool = field(default_factory=lambda: _env_bool("AUDIO_APPLY_BEETS", True))
    apply_replaygain: bool = field(default_factory=lambda: _env_bool("AUDIO_APPLY_REPLAYGAIN", True))
    download_attempt_threshold: int = field(default_factory=lambda: _env_int("AUDIO_DOWNLOAD_ATTEMPT_THRESHOLD", 10))
    download_quality_fallback: bool = field(default_factory=lambda: _env_bool("AUDIO_DOWNLOAD_QUALITY_FALLBACK", True))
    download_client_name: str = field(default_factory=lambda: _env("AUDIO_DOWNLOADCLIENT_NAME", "lidarr-deemix-sidecar"))

    # Lyric/content preferences
    lyric_type: str = field(default_factory=lambda: _env("AUDIO_LYRIC_TYPE", "prefer-explicit"))
    commentary_keywords: list[str] = field(default_factory=lambda: [k.strip().lower() for k in _env("AUDIO_COMMENTARY_KEYWORDS", "commentary,commentaries,directors commentary,audio commentary,with commentary,track by track").split(",")])
    deprioritize_commentary: bool = field(default_factory=lambda: _env_bool("AUDIO_DEPRIORITIZE_COMMENTARY_RELEASES", True))
    ignore_instrumental: bool = field(default_factory=lambda: _env_bool("AUDIO_IGNORE_INSTRUMENTAL_RELEASES", True))
    instrumental_keywords: list[str] = field(default_factory=lambda: [k.strip() for k in _env("AUDIO_INSTRUMENTAL_KEYWORDS", "Instrumental,Score").split(",")])

    # Country/format preferences
    preferred_countries: str = field(default_factory=lambda: _env("AUDIO_PREFERRED_COUNTRIES", "[Worldwide]|United States|United Kingdom|Australia|Europe|Canada|[BLANK]"))
    preferred_formats: str = field(default_factory=lambda: _env("AUDIO_PREFERRED_FORMATS", "Digital Media|CD"))

    # Intervals / limits
    interval: str = field(default_factory=lambda: _env("AUDIO_INTERVAL", "15m"))
    daily_download_limit: int = field(default_factory=lambda: _env_int("AUDIO_DAILY_DOWNLOAD_LIMIT", 0))
    retry_notfound_days: int = field(default_factory=lambda: _env_int("AUDIO_RETRY_NOTFOUND_DAYS", 90))
    retry_downloaded_days: int = field(default_factory=lambda: _env_int("AUDIO_RETRY_DOWNLOADED_DAYS", 180))
    retry_failed_days: int = field(default_factory=lambda: _env_int("AUDIO_RETRY_FAILED_DAYS", 90))

    # Cache ages
    cache_max_age_deezer: int = field(default_factory=lambda: _env_int("AUDIO_CACHE_MAX_AGE_DAYS_DEEZER", 30))
    cache_max_age_musicbrainz: int = field(default_factory=lambda: _env_int("AUDIO_CACHE_MAX_AGE_DAYS_MUSICBRAINZ", 30))

    # API settings
    deezer_api_retries: int = field(default_factory=lambda: _env_int("AUDIO_DEEZER_API_RETRIES", 3))
    deezer_api_timeout: int = field(default_factory=lambda: _env_int("AUDIO_DEEZER_API_TIMEOUT", 30))

    # Deemix/Beets custom configs
    deemix_custom_config: str = field(default_factory=lambda: _env("AUDIO_DEEMIX_CUSTOM_CONFIG", ""))
    beets_custom_config: str = field(default_factory=lambda: _env("AUDIO_BEETS_CUSTOM_CONFIG", ""))

    # Priority
    priority_only: bool = field(default_factory=lambda: _env_bool("AUDIO_PRIORITY_ONLY", False))
    priority_exempt_from_limit: bool = field(default_factory=lambda: _env_bool("AUDIO_PRIORITY_EXEMPT_FROM_LIMIT", False))

    # Result file
    result_file_name: str = field(default_factory=lambda: _env("AUDIO_RESULT_FILE_NAME", "results.md"))

    @property
    def cache_dir(self) -> Path:
        return self.work_path / "cache"

    @property
    def staging_dir(self) -> Path:
        return self.work_path / "staging"

    @property
    def complete_dir(self) -> Path:
        return self.work_path / "complete"

    @property
    def notfound_dir(self) -> Path:
        return self.data_path / "notfound"

    @property
    def downloaded_dir(self) -> Path:
        return self.data_path / "downloaded"

    @property
    def failed_dir(self) -> Path:
        return self.data_path / "failed"

    @property
    def interval_seconds(self) -> float:
        return _parse_interval(self.interval)


# Singleton instance - initialized when module is imported
cfg = Config()
