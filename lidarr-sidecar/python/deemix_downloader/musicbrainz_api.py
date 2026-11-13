#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

"""MusicBrainz API client with caching and rate-limit handling."""

from __future__ import annotations

import json
import threading
import time
from collections.abc import Iterator
from contextlib import contextmanager
from contextvars import ContextVar
from datetime import UTC, datetime
from email.utils import parsedate_to_datetime
from pathlib import Path

import requests

from .config import cfg
from .logging import log

MB_USER_AGENT = "docker-arr-sidecars/1.0.0 (https://github.com/scottfridwin/docker-arr-sidecars)"

_session: requests.Session | None = None
_last_request_time: float = 0.0
_retry_not_before: float = 0.0
_MIN_REQUEST_INTERVAL: float = 1.1  # MusicBrainz rate limit: 1 req/sec
_REQUEST_LOCK = threading.Lock()
_REQUEST_DEADLINE: ContextVar[float | None] = ContextVar("musicbrainz_request_deadline", default=None)


class MusicBrainzUnavailable(RuntimeError):
    """MusicBrainz could not be queried within the active search budget."""


@contextmanager
def request_budget(seconds: float) -> Iterator[None]:
    """Bound a group of MusicBrainz requests to one overall deadline."""
    if seconds <= 0:
        raise ValueError("MusicBrainz request budget must be positive")
    deadline = time.monotonic() + seconds
    active_deadline = _REQUEST_DEADLINE.get()
    if active_deadline is not None:
        deadline = min(deadline, active_deadline)
    token = _REQUEST_DEADLINE.set(deadline)
    try:
        yield
    finally:
        _REQUEST_DEADLINE.reset(token)


def _get_session() -> requests.Session:
    global _session
    if _session is None:
        _session = requests.Session()
        _session.headers.update(
            {
                "User-Agent": MB_USER_AGENT,
                "Accept": "application/json",
            }
        )
    return _session


def _remaining_budget() -> float | None:
    deadline = _REQUEST_DEADLINE.get()
    return None if deadline is None else deadline - time.monotonic()


def _ensure_wait_fits_budget(seconds: float) -> None:
    remaining = _remaining_budget()
    if remaining is not None and seconds >= remaining:
        raise MusicBrainzUnavailable("MusicBrainz retry would exceed the search time budget")


def _retry_after_seconds(value: str | None) -> float | None:
    if not value:
        return None
    value = value.strip()
    if value.isascii() and value.isdecimal():
        try:
            return float(int(value))
        except (ValueError, OverflowError):
            return None
    try:
        retry_at = parsedate_to_datetime(value)
    except (TypeError, ValueError, OverflowError):
        return None
    if retry_at.tzinfo is None:
        retry_at = retry_at.replace(tzinfo=UTC)
    return max(0.0, (retry_at - datetime.now(UTC)).total_seconds())


def _schedule_retry(seconds: float) -> None:
    global _retry_not_before
    with _REQUEST_LOCK:
        _retry_not_before = max(_retry_not_before, time.monotonic() + seconds)


def _request(url: str, *, backoff: float) -> tuple[requests.Response, float | None]:
    """Serialize requests and apply both the MusicBrainz interval and retry delay."""
    global _last_request_time, _retry_not_before

    with _REQUEST_LOCK:
        now = time.monotonic()
        interval_wait = _MIN_REQUEST_INTERVAL - (now - _last_request_time)
        retry_wait = _retry_not_before - now
        wait = max(interval_wait, retry_wait, 0.0)
        _ensure_wait_fits_budget(wait)
        if wait:
            time.sleep(wait)

        remaining = _remaining_budget()
        if remaining is not None and remaining <= 0:
            raise MusicBrainzUnavailable("MusicBrainz search exceeded the time budget")

        timeout = min(15.0, remaining / 2) if remaining is not None else 15.0
        _last_request_time = time.monotonic()
        try:
            response = _get_session().get(url, timeout=timeout, allow_redirects=True)
        except requests.RequestException:
            _retry_not_before = max(_retry_not_before, time.monotonic() + backoff)
            raise

        remaining_after_request = _remaining_budget()
        if remaining_after_request is not None and remaining_after_request <= 0:
            raise MusicBrainzUnavailable("MusicBrainz request exceeded the search time budget")

        retry_after = _retry_after_seconds(response.headers.get("Retry-After"))
        if response.status_code in (429, 503) or response.status_code >= 500:
            delay = backoff if retry_after is None else retry_after
            _retry_not_before = max(_retry_not_before, time.monotonic() + delay)
            return response, delay

        return response, None


def call_musicbrainz_api(url: str) -> dict | None:
    """
    Call MusicBrainz API with serialized rate limiting and Retry-After handling.
    Returns parsed JSON or None.
    """
    max_attempts = 10
    backoff = 5.0

    for attempt in range(1, max_attempts + 1):
        log.debug(f"Calling MusicBrainz API ({attempt}/{max_attempts}): {url}")
        try:
            resp, retry_delay = _request(url, backoff=backoff)
            if resp.status_code == 200:
                try:
                    return resp.json()
                except ValueError:
                    log.warning("Invalid JSON from MusicBrainz, retrying...")
                    retry_delay = backoff
                    _schedule_retry(retry_delay)
            elif resp.status_code == 429 or resp.status_code >= 500:
                delay = backoff if retry_delay is None else retry_delay
                log.warning(f"HTTP {resp.status_code} from MusicBrainz, retrying in {delay:g}s...")
                if attempt < max_attempts:
                    _ensure_wait_fits_budget(delay)
                backoff = min(backoff * 2, 30.0)
                continue
            else:
                log.warning(f"Unexpected HTTP {resp.status_code} from MusicBrainz")
                return None

        except requests.RequestException as e:
            log.warning(f"MusicBrainz request failed: {e}, retrying...")
            if attempt < max_attempts:
                _ensure_wait_fits_budget(backoff)
            backoff = min(backoff * 2, 30.0)

    log.error(f"CallMusicBrainzAPI failed after {max_attempts} attempts")
    if _REQUEST_DEADLINE.get() is not None:
        raise MusicBrainzUnavailable("MusicBrainz remained unavailable after retries")
    return None


def _read_cached_json(cache_file: Path) -> dict | None:
    if not cache_file.is_file():
        return None

    try:
        data = json.loads(cache_file.read_text(encoding="utf-8"))
        if isinstance(data, dict):
            return data
    except (json.JSONDecodeError, OSError):
        pass
    return None


def _write_cached_json(cache_file: Path, data: dict, *, shorter_cache: bool = False) -> None:
    try:
        cache_file.parent.mkdir(parents=True, exist_ok=True)
        cache_file.write_text(json.dumps(data), encoding="utf-8")
        if shorter_cache:
            # Set mtime to be 23 days old so it expires in ~7 days instead of 30
            import os as _os

            age_offset = (cfg.cache_max_age_musicbrainz - 7) * 86400
            now = time.time()
            _os.utime(cache_file, (now - age_offset, now - age_offset))
    except OSError:
        pass


def fetch_musicbrainz_release(mbid: str) -> dict | None:
    """
    Fetch MusicBrainz release info with caching.
    Includes recordings and url-rels.
    """
    if not mbid or mbid == "null":
        return None

    cache_file = cfg.cache_dir / f"mb-release-{mbid}.json"

    cached = _read_cached_json(cache_file)
    if cached is not None:
        log.debug(f"Using cached MB release for {mbid}")
        return cached

    url = f"https://musicbrainz.org/ws/2/release/{mbid}?fmt=json&inc=recordings+release-groups+url-rels"
    data = call_musicbrainz_api(url)

    if data is not None:
        # Use shorter cache for releases without Deezer links (they may get updated)
        has_deezer = any("deezer.com" in (r.get("url", {}).get("resource", "")) for r in data.get("relations", []))
        _write_cached_json(cache_file, data, shorter_cache=not has_deezer)

    return data


def fetch_musicbrainz_release_group(mbid: str) -> dict | None:
    """Fetch MusicBrainz release-group info with caching and alias support."""
    if not mbid or mbid == "null":
        return None

    cache_file = cfg.cache_dir / f"mb-release-group-{mbid}.json"

    cached = _read_cached_json(cache_file)
    if cached is not None:
        log.debug(f"Using cached MB release group for {mbid}")
        return cached

    url = f"https://musicbrainz.org/ws/2/release-group/{mbid}?fmt=json&inc=aliases"
    data = call_musicbrainz_api(url)

    if data is not None:
        _write_cached_json(cache_file, data)

    return data
