#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

"""
DeemixDownloader main service.

Orchestrates:
1. Setup (Deemix, Beets, download client)
2. Polling Lidarr's wanted list
3. Finding Deezer matches via MusicBrainz links
4. Downloading, tagging, and importing
"""

from __future__ import annotations

import contextlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unicodedata
from collections.abc import Callable
from datetime import date
from pathlib import Path
from typing import Any
from urllib.parse import quote_plus

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "../..")))

from shared.python.arrapi import arr_api_request, verify_arr_api_access
from shared.python.state import get_state, init_state

from . import musicbrainz_api
from .config import cfg
from .download import (
    AUDIO_EXTENSIONS,
    apply_beets,
    apply_replaygain,
    clean_staging,
    consolidate_files,
    download_with_deemix,
    get_file_disc_track_numbers,
    move_to_import,
    prune_cache,
    remove_existing_import_flac_files,
    setup_working_dirs,
    tag_flac_artist,
    tag_flac_musicbrainz,
    tag_mp3_mutagen,
    verify_flac,
)
from .indexer_search import AmbiguousAlbumError, resolve_album
from .lidarr_api import (
    add_download_client,
    get_album_data,
    get_album_ids_by_artist,
    get_album_ids_by_release_group,
    get_wanted_albums,
    manual_import_release,
    notify_lidarr_import,
    remove_lidarr_queue_items,
    scan_import_and_verify,
)
from .logging import log
from .matching import MatchResult, ReleaseCandidate, find_best_match
from .musicbrainz_api import fetch_musicbrainz_release, fetch_musicbrainz_release_group
from .string_utils import calculate_priority, normalize_string, remove_punctuation

# ─── Constants ─────────────────────────────────────────────────────────

DEEMIX_DIR = Path("/tmp/deemix")
DEEMIX_CONFIG_PATH = DEEMIX_DIR / "config" / "config.json"
BEETS_DIR = Path("/tmp/beets")
BEETS_CONFIG_PATH = BEETS_DIR / "beets.yaml"

# Pre-compiled keyword patterns (built once from config)
_COMMENTARY_RE = (
    re.compile("|".join(re.escape(k) for k in cfg.commentary_keywords), re.IGNORECASE)
    if cfg.commentary_keywords
    else None
)
_INSTRUMENTAL_RE = (
    re.compile("|".join(re.escape(k) for k in cfg.instrumental_keywords), re.IGNORECASE)
    if cfg.instrumental_keywords
    else None
)
_LIDARR_API_LOCK = threading.RLock()
_INDEXER_MUSICBRAINZ_BUDGET_SECONDS = 60.0


# ─── Daily download limit ──────────────────────────────────────────────


class DailyLimitTracker:
    """Track daily download count with file persistence."""

    def __init__(self):
        self._state_file = cfg.work_path / "daily_download_state"
        self._date: str = ""
        self._count: int = 0
        self._load()

    def _load(self) -> None:
        cfg.work_path.mkdir(parents=True, exist_ok=True)
        today = date.today().isoformat()
        if self._state_file.is_file():
            try:
                parts = self._state_file.read_text().strip().split()
                if len(parts) >= 2 and parts[0] == today:
                    self._date = parts[0]
                    self._count = int(parts[1])
                    return
            except (ValueError, OSError):
                pass
        self._date = today
        self._count = 0
        self._save()

    def _save(self) -> None:
        tmp = self._state_file.with_suffix(".tmp")
        tmp.write_text(f"{self._date} {self._count}")
        tmp.rename(self._state_file)

    def is_limit_reached(self) -> bool:
        if cfg.daily_download_limit <= 0:
            return False
        self._load()
        return self._count >= cfg.daily_download_limit

    def increment(self) -> None:
        if cfg.daily_download_limit <= 0:
            return
        self._load()
        self._count += 1
        self._save()


# ─── Setup ───────────────────────────────────────────────────────────────


def setup_deemix() -> str:
    """Set up Deemix configuration. Returns ARL token."""
    log.debug("Setting up Deemix client")

    if not cfg.deemix_arl_file.is_file():
        log.fatal("No Deemix ARL token file found")

    arl_token = cfg.deemix_arl_file.read_text(encoding="utf-8").strip().strip('\r\n"')

    default_config = Path("/app/config/deemix_config.json")
    if not default_config.is_file():
        log.fatal(f"Default Deemix config not found: {default_config}")

    DEEMIX_DIR.mkdir(parents=True, exist_ok=True)
    (DEEMIX_DIR / "config").mkdir(parents=True, exist_ok=True)
    shutil.copy2(str(default_config), str(DEEMIX_CONFIG_PATH))

    # Merge custom config if provided
    if cfg.deemix_custom_config:
        try:
            custom_path = Path(cfg.deemix_custom_config)
            if custom_path.is_file():
                custom = json.loads(custom_path.read_text())
            else:
                custom = json.loads(cfg.deemix_custom_config)
            base = json.loads(DEEMIX_CONFIG_PATH.read_text())
            base.update(custom)
            DEEMIX_CONFIG_PATH.write_text(json.dumps(base, indent=2))
            log.debug("Custom Deemix config merged")
        except (json.JSONDecodeError, OSError) as e:
            log.warning(f"Failed to merge custom Deemix config: {e}")

    log.debug("Deemix setup complete")
    return arl_token


def setup_beets() -> None:
    """Set up Beets configuration."""
    log.debug("Setting up Beets configuration")

    default_config = Path("/app/config/beets_config.yaml")
    if not default_config.is_file():
        log.fatal(f"Default Beets config not found: {default_config}")

    BEETS_DIR.mkdir(parents=True, exist_ok=True)
    shutil.copy2(str(default_config), str(BEETS_CONFIG_PATH))

    if cfg.beets_custom_config:
        try:
            custom_path = Path(cfg.beets_custom_config)
            content = custom_path.read_text() if custom_path.is_file() else cfg.beets_custom_config
            import subprocess

            result = subprocess.run(
                [
                    "yq",
                    "eval-all",
                    "select(fileIndex == 0) * select(fileIndex == 1)",
                    str(BEETS_CONFIG_PATH),
                    "-",
                ],
                input=content,
                capture_output=True,
                text=True,
            )
            if result.returncode == 0:
                BEETS_CONFIG_PATH.write_text(result.stdout)
                log.debug("Custom Beets config merged")
            else:
                log.warning(f"Failed to merge Beets config: {result.stderr}")
        except (OSError, FileNotFoundError) as e:
            log.warning(f"Failed to merge custom Beets config: {e}")

    log.debug("Beets configuration complete")


# ─── Folder cleanup ─────────────────────────────────────────────────────


def folder_cleaner() -> None:
    """Remove old notfound/downloaded/failed entries to allow retries."""
    now = time.time()

    def _clean(directory: Path, max_days: int) -> None:
        if not directory.is_dir() or max_days <= 0:
            return
        max_age = max_days * 86400
        for f in directory.iterdir():
            if f.is_file() and (now - f.stat().st_mtime) > max_age:
                f.unlink(missing_ok=True)

    _clean(cfg.notfound_dir, cfg.retry_notfound_days)
    _clean(cfg.downloaded_dir, cfg.retry_downloaded_days)
    _clean(cfg.failed_dir, cfg.retry_failed_days)


# ─── State helpers ───────────────────────────────────────────────────────


def _get_marker_ids(directory: Path) -> set[str]:
    """Get album IDs from marker files (ID is first part before --)."""
    ids: set[str] = set()
    if directory.is_dir():
        for f in directory.iterdir():
            if f.is_file():
                ids.add(f.name.split("--")[0])
    return ids


def _get_failed_albums() -> set[str]:
    """Get set of Deezer album IDs that have previously failed."""
    failed: set[str] = set()
    if cfg.failed_dir.is_dir():
        for f in cfg.failed_dir.iterdir():
            if f.is_file():
                failed.add(f.name)
    return failed


# ─── Build release candidates from Lidarr album data ────────────────────


def _build_candidates(album_data: dict, album_release_year: str) -> list[ReleaseCandidate]:
    """
    Build ReleaseCandidate objects from Lidarr album releases.
    Fetches MusicBrainz data to extract Deezer links.
    """
    candidates: list[ReleaseCandidate] = []

    for release_json in album_data.get("releases", []):
        title = release_json.get("title", "")
        disambiguation = release_json.get("disambiguation", "") or ""
        release_id = str(release_json.get("id", "") or "")
        track_count = release_json.get("trackCount", 0)
        foreign_release_id = release_json.get("foreignReleaseId", "")
        release_format = release_json.get("format", "")
        countries = release_json.get("country", [])
        countries_str = ",".join(countries) if isinstance(countries, list) else str(countries or "")

        format_priority = calculate_priority(release_format, cfg.preferred_formats)
        country_priority = calculate_priority(countries_str, cfg.preferred_countries)

        # Fetch MusicBrainz release to get Deezer link
        mb_data = fetch_musicbrainz_release(foreign_release_id)
        if mb_data is None:
            continue

        release_status = mb_data.get("status", "")
        musicbrainz_barcode = str(mb_data.get("barcode", "") or "")

        # Extract Deezer album ID from MB relations
        deezer_album_id = ""
        for rel in mb_data.get("relations", []):
            if rel.get("ended", True):
                continue
            url = rel.get("url", {}).get("resource", "")
            match = re.search(r"deezer\.com/album/(\d+)", url)
            if match:
                deezer_album_id = match.group(1)
                break

        # Determine year
        release_date = release_json.get("releaseDate", "")
        if release_date and release_date != "null":
            year = release_date[:4]
        else:
            mb_date = mb_data.get("date", "")
            year = mb_date[:4] if mb_date else album_release_year

        alternate_titles: list[str] = []
        release_group = mb_data.get("release-group", {})
        if isinstance(release_group, dict):
            release_group_id = release_group.get("id", "")
            if release_group_id:
                log.debug(f"Fetching MusicBrainz aliases for release-group {release_group_id}")
                release_group_data = fetch_musicbrainz_release_group(release_group_id)
                if release_group_data is not None:
                    aliases = release_group_data.get("aliases", [])
                    if isinstance(aliases, list):
                        alternate_titles = [
                            alias.get("name", "") for alias in aliases if isinstance(alias, dict) and alias.get("name")
                        ]
                        if alternate_titles:
                            log.debug(
                                f"Found {len(alternate_titles)} release-group aliases for {release_group_id}: "
                                f"{', '.join(alternate_titles[:5])}"
                            )

        # Check commentary
        contains_commentary = bool(
            _COMMENTARY_RE and (_COMMENTARY_RE.search(title) or _COMMENTARY_RE.search(disambiguation))
        )

        # Check instrumental
        instrumental = bool(
            _INSTRUMENTAL_RE and (_INSTRUMENTAL_RE.search(title) or _INSTRUMENTAL_RE.search(disambiguation))
        )

        candidates.append(
            ReleaseCandidate(
                title=title,
                disambiguation=disambiguation,
                release_id=release_id,
                foreign_id=foreign_release_id,
                track_count=track_count,
                deezer_album_id=deezer_album_id,
                release_status=release_status,
                year=year,
                format_priority=format_priority,
                country_priority=country_priority,
                contains_commentary=contains_commentary,
                instrumental=instrumental,
                alternate_titles=alternate_titles,
                musicbrainz_barcode=musicbrainz_barcode,
            )
        )

    return candidates


# ─── Search and download ─────────────────────────────────────────────────


def search_album(album_data: dict, failed_albums: set[str] | None = None) -> MatchResult:
    """Find a Deezer match without changing download or import state."""
    album_title = remove_punctuation(normalize_string(album_data.get("title", "")))
    release_date = album_data.get("releaseDate", "") or ""
    candidates = _build_candidates(album_data, release_date[:4])
    return find_best_match(candidates, album_title, failed_albums if failed_albums is not None else set())


def _indexer_key(value: str) -> str:
    return " ".join(unicodedata.normalize("NFKC", normalize_string(value)).replace("+", " ").casefold().split())


def _indexer_api_get(path: str) -> Any:
    with _LIDARR_API_LOCK:
        arr_api_request("GET", path)
        code = get_state("arrApiReponseCode")
        if code and int(code) >= 400:
            raise RuntimeError(f"Lidarr API returned HTTP {code}")
        response = get_state("arrApiResponse")
    if isinstance(response, str):
        try:
            return json.loads(response)
        except json.JSONDecodeError as exc:
            raise RuntimeError("Lidarr returned invalid JSON") from exc
    return response


def _find_indexer_artists(name: str) -> list[dict]:
    if not name.strip():
        return []
    response = _indexer_api_get(f"artist?term={quote_plus(name)}")
    if isinstance(response, dict):
        response = [response]
    if not isinstance(response, list):
        raise RuntimeError("Lidarr artist search returned an unexpected response")
    wanted = _indexer_key(name)
    return [
        artist
        for artist in response
        if isinstance(artist, dict)
        and isinstance(artist.get("artistName"), str)
        and _indexer_key(artist["artistName"]) == wanted
    ]


def _indexer_artist_albums(artist: dict) -> list[dict]:
    artist_id = artist.get("id")
    if not artist_id:
        return []
    response = _indexer_api_get(f"album?artistId={quote_plus(str(artist_id))}&includeArtist=true")
    if isinstance(response, dict):
        response = [response]
    if not isinstance(response, list):
        raise RuntimeError("Lidarr album search returned an unexpected response")
    albums = []
    for album in response:
        if not isinstance(album, dict):
            continue
        album_artist = album.get("artist")
        if not isinstance(album_artist, dict):
            album = {**album, "artist": artist}
        albums.append(album)
    return albums


def _indexer_release_payload(album_data: dict, match: MatchResult) -> dict | None:
    artist = album_data.get("artist")
    if not isinstance(artist, dict) or not match.matched:
        return None
    release = next(
        (
            candidate
            for candidate in album_data.get("releases", [])
            if str(candidate.get("id", "")) == str(match.lidarr_release_id)
        ),
        None,
    )
    if not release or not all((artist.get("id"), album_data.get("id"), release.get("id"))):
        return None
    return {
        "artist_id": str(artist["id"]),
        "artist_name": str(artist.get("artistName") or ""),
        "artist_foreign_id": str(artist.get("foreignArtistId") or ""),
        "album_id": str(album_data["id"]),
        "album_title": str(album_data.get("title") or ""),
        "album_foreign_id": str(album_data.get("foreignAlbumId") or ""),
        "release_id": str(release["id"]),
        "release_foreign_id": str(match.lidarr_release_foreign_id),
        "release_title": str(release.get("title") or album_data.get("title") or ""),
        "deezer_album_id": str(match.deezer_album_id),
        "deezer_title": str(match.deezer_title),
        "year": str(match.deezer_year),
        "track_count": int(match.deezer_track_count),
    }


def _indexer_match_album(album: dict, year: int | None) -> dict | None:
    album_id = album.get("id")
    if not album_id:
        return None
    with _LIDARR_API_LOCK:
        full_album = get_album_data(str(album_id))
    if not full_album:
        return None
    if year is not None:
        release_date = full_album.get("releaseDate") or ""
        if not isinstance(release_date, str) or release_date[:4] != str(year):
            return None
    match = search_album(full_album, set())
    return _indexer_release_payload(full_album, match)


def search_indexer_releases(*, artist: str, album: str, q: str, year: int | None, request_type: str) -> list[dict]:
    """Resolve Lidarr's actual Newznab text requests against its local library."""
    with musicbrainz_api.request_budget(_INDEXER_MUSICBRAINZ_BUDGET_SECONDS):
        return _search_indexer_releases(artist=artist, album=album, q=q, year=year, request_type=request_type)


def _indexer_artist_releases(artists: list[dict], year: int | None) -> list[dict]:
    if len(artists) > 1:
        raise AmbiguousAlbumError("Artist search matches multiple Lidarr artists")
    if not artists:
        return []
    results = []
    for candidate in _indexer_artist_albums(artists[0]):
        payload = _indexer_match_album(candidate, year)
        if payload:
            results.append(payload)
    return results[:100]


def _search_indexer_releases(*, artist: str, album: str, q: str, year: int | None, request_type: str) -> list[dict]:
    searches: list[tuple[str, str, int | None]] = []
    if artist:
        if album:
            searches.append((artist, album, year))
        else:
            return _indexer_artist_releases(_find_indexer_artists(artist), year)
    elif q:
        words = q.split()
        artists = _find_indexer_artists(q)
        if artists:
            return _indexer_artist_releases(artists, year)
        if year is None and words and len(words[-1]) == 4 and words[-1].isascii() and words[-1].isdecimal():
            year = int(words.pop())
            artists = _find_indexer_artists(" ".join(words))
            if artists:
                return _indexer_artist_releases(artists, year)
        if len(words) == 1:
            return []
        for split in range(1, len(words)):
            searches.append((" ".join(words[:split]), " ".join(words[split:]), year))
    else:
        raise ValueError(f"unsupported {request_type} query")

    matches: dict[str, dict] = {}
    for artist_query, album_query, query_year in searches:
        artists = _find_indexer_artists(artist_query)
        if len(artists) > 1:
            raise AmbiguousAlbumError("Artist and album terms match multiple Lidarr artists")
        if not artists:
            continue
        candidates = _indexer_artist_albums(artists[0])
        selected = resolve_album(candidates, artist_query, album_query, year=query_year)
        if selected is None:
            continue
        payload = _indexer_match_album(selected, query_year)
        if payload:
            matches[payload["album_id"]] = payload
    if len(matches) > 1:
        raise AmbiguousAlbumError("Text search matches multiple Lidarr albums")
    return list(matches.values())


def download_indexer_release(
    release: dict,
    on_download_complete: Callable[[], None],
    arl_token: str,
) -> bool:
    """Download a grabbed result and force the exact Lidarr release import."""
    result = MatchResult(
        deezer_album_id=release["deezer_album_id"],
        deezer_title=release["deezer_title"],
        deezer_year=release["year"],
        deezer_track_count=release["track_count"],
        lidarr_release_id=release["release_id"],
        lidarr_release_foreign_id=release["release_foreign_id"],
        matched=True,
    )
    imported = _download_album(
        result,
        artist_name=release["artist_name"],
        artist_id=release["artist_id"],
        artist_foreign_id=release["artist_foreign_id"],
        album_title=release["album_title"],
        album_foreign_id=release["album_foreign_id"],
        album_id=release["album_id"],
        arl_token=arl_token,
        strict_manual_import=True,
        ignore_failure_marker=True,
        on_download_complete=on_download_complete,
    )
    if imported:
        download_ids = release.get("lidarr_download_ids") or []
        with _LIDARR_API_LOCK:
            remove_lidarr_queue_items(download_ids)
    return imported


def search_and_download(
    album_id: str,
    failed_albums: set[str],
    daily_tracker: DailyLimitTracker,
    arl_token: str,
    priority_entry: str = "",
) -> None:
    """Search for a Deezer match and download if found."""
    album_data = get_album_data(album_id)
    if album_data is None:
        return

    # Extract metadata
    artist_data = album_data.get("artist", {})
    artist_name = artist_data.get("artistName", "")
    artist_foreign_id = artist_data.get("foreignArtistId", "")
    album_title_raw = album_data.get("title", "")
    album_title = remove_punctuation(normalize_string(album_title_raw))  # For matching comparison
    album_foreign_id = album_data.get("foreignAlbumId", "")
    album_release_date = album_data.get("releaseDate", "") or ""

    # Check if not yet released
    if album_release_date:
        release_clean = re.sub(r"[^0-9]", "", album_release_date[:10])
        today_clean = time.strftime("%Y%m%d")
        if release_clean and today_clean < release_clean:
            log.debug(f'Album "{album_title}" not yet released, skipping')
            return

    # Check existing markers
    marker = f"{album_id}--{artist_foreign_id}--{album_foreign_id}"
    if cfg.notfound_dir.is_dir() and (cfg.notfound_dir / marker).exists():
        log.debug(f'Album "{album_title}" previously marked not found, skipping')
        return
    if cfg.downloaded_dir.is_dir() and (cfg.downloaded_dir / marker).exists():
        log.debug(f'Album "{album_title}" previously downloaded, skipping')
        return

    log.info(f'Searching for album "{album_title}" by "{artist_name}"')

    result = search_album(album_data, failed_albums)

    # Write result file
    _write_result_file(album_id, artist_name, album_title, album_foreign_id, result)

    if result.matched:
        success = _download_album(
            result,
            artist_name,
            str(artist_data.get("id", "") or ""),
            artist_foreign_id,
            album_title_raw,
            album_foreign_id,
            album_id,
            arl_token,
            priority_entry=priority_entry,
        )
        if success:
            _remove_from_missing_file(album_id)
            daily_tracker.increment()
    else:
        log.info(f"No match: {result.reason}")
        _upsert_missing_file(album_id, artist_name, album_title, album_foreign_id, result.reason)
        # Mark as not found (unless it's a new release)
        is_new = False
        if album_release_date:
            release_clean = re.sub(r"[^0-9]", "", album_release_date[:10])
            today_clean = time.strftime("%Y%m%d")
            if release_clean:
                is_new = (int(today_clean) - int(release_clean)) < 8
        if not is_new:
            cfg.notfound_dir.mkdir(parents=True, exist_ok=True)
            (cfg.notfound_dir / marker).touch()


def _tag_and_enrich(
    directory: Path,
    artist_name: str,
    artist_foreign_id: str,
    album_title: str,
    release_foreign_id: str,
    album_foreign_id: str,
    deezer_album_id: str,
    downloaded_timestamp: str,
) -> None:
    """Tag files in `directory` with MusicBrainz/Deezer info, then apply
    ReplayGain and Beets. Shared by both deemix downloads and manual imports."""
    track_id_map: dict[tuple[int, int], tuple[str, str]] = {}
    release_data = fetch_musicbrainz_release(release_foreign_id)
    if isinstance(release_data, dict):
        track_id_map = _build_release_track_id_map(release_data)

    # Tag with MusicBrainz info
    for f in directory.iterdir():
        if not f.is_file():
            continue
        if f.suffix.lower() == ".flac":
            disc_num, track_num = get_file_disc_track_numbers(f)
            rec_id, rel_track_id = ("", "")
            if disc_num is not None and track_num is not None:
                rec_id, rel_track_id = track_id_map.get((disc_num, track_num), ("", ""))
            tag_flac_musicbrainz(
                f,
                album_title,
                release_foreign_id,
                album_foreign_id,
                recording_mb_id=rec_id,
                release_track_mb_id=rel_track_id,
                deezer_album_id=deezer_album_id,
                date_downloaded=downloaded_timestamp,
            )
        elif f.suffix.lower() == ".mp3":
            disc_num, track_num = get_file_disc_track_numbers(f)
            rec_id, rel_track_id = ("", "")
            if disc_num is not None and track_num is not None:
                rec_id, rel_track_id = track_id_map.get((disc_num, track_num), ("", ""))
            tag_mp3_mutagen(
                f,
                album_title=album_title,
                release_id=release_foreign_id,
                release_group_id=album_foreign_id,
                recording_mb_id=rec_id,
                release_track_mb_id=rel_track_id,
                deezer_album_id=deezer_album_id,
                date_downloaded=downloaded_timestamp,
            )

    # ReplayGain
    if cfg.apply_replaygain:
        apply_replaygain(directory)

    # Beets
    beets_ok = False
    if cfg.apply_beets:
        beets_ok = apply_beets(directory, release_foreign_id, BEETS_CONFIG_PATH, BEETS_DIR)

    # Artist tags: only reassert the album-level Lidarr artist when Beets didn't
    # run or failed. Otherwise, leave Beets' own per-track match in place, since
    # it can be more accurate than the album-level artist on compilations.
    if not beets_ok:
        for f in directory.iterdir():
            if not f.is_file():
                continue
            if f.suffix.lower() == ".flac":
                tag_flac_artist(f, artist_name, artist_foreign_id)
            elif f.suffix.lower() == ".mp3":
                tag_mp3_mutagen(f, artist_name=artist_name, artist_foreign_id=artist_foreign_id)


def _download_track_identity(file_path: Path) -> tuple[str, int, int] | tuple[str, str]:
    disc_number, track_number = get_file_disc_track_numbers(file_path)
    if track_number is not None:
        return "track", disc_number or 1, track_number
    return "filename", file_path.name.casefold()


def _merge_download_attempt(attempt_dir: Path) -> int:
    cfg.staging_dir.mkdir(parents=True, exist_ok=True)
    known_tracks = {
        _download_track_identity(file_path)
        for file_path in cfg.staging_dir.rglob("*")
        if file_path.is_file() and file_path.suffix.lower() in AUDIO_EXTENSIONS
    }

    for file_path in sorted(attempt_dir.rglob("*")):
        if not file_path.is_file() or file_path.suffix.lower() not in AUDIO_EXTENSIONS:
            continue
        if file_path.suffix.lower() == ".flac" and not verify_flac(file_path):
            log.warning(f"FLAC verification failed: {file_path.name}, removing")
            file_path.unlink()
            continue

        identity = _download_track_identity(file_path)
        if identity in known_tracks:
            log.debug(f"Skipping duplicate track from retry: {file_path.name}")
            continue

        destination = cfg.staging_dir / file_path.name
        suffix = 2
        while destination.exists():
            destination = cfg.staging_dir / f"{file_path.stem}_{suffix}{file_path.suffix}"
            suffix += 1
        shutil.move(str(file_path), str(destination))
        known_tracks.add(identity)

    return len(known_tracks)


def _download_album(
    result: MatchResult,
    artist_name: str,
    artist_id: str,
    artist_foreign_id: str,
    album_title: str,
    album_foreign_id: str,
    album_id: str,
    arl_token: str,
    priority_entry: str = "",
    *,
    strict_manual_import: bool = False,
    ignore_failure_marker: bool = False,
    on_download_complete: Callable[[], None] | None = None,
) -> bool:
    """Download, tag, and import an album. Returns True on success."""
    deezer_album_id = result.deezer_album_id
    deezer_title = result.deezer_title
    deezer_track_count = result.deezer_track_count
    release_year = result.deezer_year

    if strict_manual_import and not (artist_id and album_id and result.lidarr_release_id):
        log.error("Cannot force manual import without Lidarr artist, album, and release IDs")
        return False

    # Check previously failed
    if not ignore_failure_marker and (cfg.failed_dir / deezer_album_id).exists():
        log.warning(f'Album "{deezer_title}" previously failed, skipping')
        return False

    if not cfg.shared_lidarr_path.is_dir():
        log.error(f"Shared Lidarr path not found: {cfg.shared_lidarr_path}")
        return False

    log.info(f"Downloading: [{deezer_album_id}] {deezer_title} ({release_year})")

    attempt_limit = max(1, cfg.download_attempt_threshold)
    qualities = ["flac", "mp3"] if cfg.download_quality_fallback else ["flac"]
    clean_staging()
    complete = False

    for quality_index, quality in enumerate(qualities):
        if quality_index > 0:
            log.warning(f"Failed to collect all tracks after {attempt_limit} FLAC attempts, trying mp3 fallback")
            remove_existing_import_flac_files(
                artist_name,
                album_title,
                release_year,
                album_foreign_id,
            )
            clean_staging()

        for attempt in range(1, attempt_limit + 1):
            log.debug(f"Download attempt #{attempt}/{attempt_limit} ({quality})")
            with tempfile.TemporaryDirectory(prefix="deemix-attempt-", dir=cfg.work_path) as temp_dir:
                deemix_success = download_with_deemix(
                    deezer_album_id,
                    arl_token,
                    quality,
                    DEEMIX_DIR,
                    output_dir=Path(temp_dir),
                )
                if not deemix_success:
                    log.warning(
                        f"Deemix reported failure on attempt #{attempt}/{attempt_limit} ({quality}); "
                        "keeping any completed tracks"
                    )
                collected_count = _merge_download_attempt(Path(temp_dir))

            log.debug(f"Collected {collected_count}/{deezer_track_count} distinct tracks ({quality})")
            if collected_count == deezer_track_count:
                complete = True
                break

            log.warning(
                f"Expected {deezer_track_count} distinct tracks, got {collected_count} "
                f"after attempt #{attempt}/{attempt_limit} ({quality})"
            )
            if attempt < attempt_limit:
                time.sleep(1)

        if complete:
            break

    if not complete:
        log.warning(
            f"Failed to collect all tracks after exhausting {attempt_limit} attempts for each quality, giving up"
        )
        cfg.failed_dir.mkdir(parents=True, exist_ok=True)
        (cfg.failed_dir / deezer_album_id).touch()
        clean_staging()
        return False

    if on_download_complete is not None:
        on_download_complete()

    # Post-processing
    consolidate_files(cfg.staging_dir)
    downloaded_timestamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

    release_foreign_id = result.lidarr_release_foreign_id
    release_lidarr_id = result.lidarr_release_id

    _tag_and_enrich(
        cfg.staging_dir,
        artist_name,
        artist_foreign_id,
        album_title,
        release_foreign_id,
        album_foreign_id,
        deezer_album_id,
        downloaded_timestamp,
    )

    # Move and import
    dest = move_to_import(artist_name, album_title, release_year, album_foreign_id)
    import_ok = True
    if strict_manual_import or cfg.import_strategy == "manual":
        if not (artist_id and album_id and release_lidarr_id):
            log.warning("Manual import strategy requested but missing internal IDs; using scan import")
            if album_id:
                import_ok, scan_errors = scan_import_and_verify(str(dest), album_id)
                for message in scan_errors:
                    log.error(f"  scan: {message}")
            else:
                notify_lidarr_import(str(dest))
                import_ok = True
        else:
            with _LIDARR_API_LOCK:
                import_ok, rejections = manual_import_release(
                    import_path=str(dest),
                    artist_id=artist_id,
                    album_id=album_id,
                    release_id=release_lidarr_id,
                )
            if not import_ok:
                log.error(
                    f'Manual import rejected "{deezer_title}" (forced MusicBrainz '
                    "release does not match the downloaded files):"
                )
                for rejection in rejections[:20]:
                    log.error(f"  - {rejection}")
                if cfg.import_manual_fallback_to_scan and not strict_manual_import:
                    log.warning("Attempting verified DownloadedAlbumsScan fallback")
                    import_ok, scan_errors = scan_import_and_verify(str(dest), album_id)
                    for message in scan_errors:
                        log.error(f"  scan fallback: {message}")
    else:
        notify_lidarr_import(str(dest))

    if not import_ok:
        log.error(f'Import FAILED for "{deezer_title}"; leaving files in {dest} for manual review')
        cfg.failed_dir.mkdir(parents=True, exist_ok=True)
        (cfg.failed_dir / deezer_album_id).touch()
        return False

    # Mark downloaded
    marker = f"{album_id}--{artist_foreign_id}--{album_foreign_id}"
    cfg.downloaded_dir.mkdir(parents=True, exist_ok=True)
    (cfg.downloaded_dir / marker).touch()

    # Remove from priority file (use original entry if from a prefixed source)
    entry_to_remove = priority_entry if priority_entry else album_id
    # Don't remove mb_artist: entries since they represent multiple albums
    if not entry_to_remove.startswith("mb_artist:"):
        _remove_from_priority_file(entry_to_remove)

    log.info(f'Successfully downloaded "{deezer_title}"')
    clean_staging()
    return True


def _build_release_track_id_map(
    release_data: dict,
) -> dict[tuple[int, int], tuple[str, str]]:
    """Build mapping of (disc, track_number) -> (recording_mbid, release_track_mbid)."""
    mapping: dict[tuple[int, int], tuple[str, str]] = {}
    media = release_data.get("media", [])
    if not isinstance(media, list):
        return mapping

    for medium in media:
        if not isinstance(medium, dict):
            continue
        disc_raw = medium.get("position", 1)
        try:
            disc_num = int(disc_raw)
        except (TypeError, ValueError):
            disc_num = 1

        tracks = medium.get("tracks", [])
        if not isinstance(tracks, list):
            continue

        for idx, track in enumerate(tracks, start=1):
            if not isinstance(track, dict):
                continue
            track_raw = track.get("number") or track.get("position") or idx
            try:
                track_num = int(str(track_raw).split("/")[0])
            except (TypeError, ValueError):
                track_num = idx

            recording_id = ""
            recording = track.get("recording", {})
            if isinstance(recording, dict):
                recording_id = str(recording.get("id", "") or "")

            release_track_id = str(track.get("id", "") or "")
            if recording_id or release_track_id:
                mapping[(disc_num, track_num)] = (recording_id, release_track_id)

    return mapping


def _manual_import_supported_extensions() -> set[str]:
    """Supported input extensions for manual imports.

    By default the import must already be FLAC/MP3. When explicitly enabled,
    lossy formats such as M4A/Opus can be converted to MP3 before tagging.
    """
    allowed = {".flac", ".mp3"}
    if cfg.manual_import_convert_to_mp3:
        allowed |= {".m4a", ".opus", ".aac", ".wav"}
    return allowed


def _validate_manual_import_files(source_dir: Path) -> tuple[bool, str]:
    """Validate the manual-import input set before tagging.

    Returns (ok, message). If conversion is disabled, any non-FLAC/MP3 file is
    rejected. When enabled, m4a/opus/aac/wav files are allowed and converted to
    MP3 before tagging.
    """
    if not source_dir.is_dir():
        return False, f"Source folder not found: {source_dir}"

    audio_files = [f for f in source_dir.rglob("*") if f.is_file() and f.suffix.lower()]
    if not audio_files:
        return False, f"No audio files found in {source_dir}"

    unsupported = sorted({f.name for f in audio_files if f.suffix.lower() not in _manual_import_supported_extensions()})
    if unsupported:
        if cfg.manual_import_convert_to_mp3:
            return False, (
                "Manual import file conversion is enabled, but some files are still unsupported: "
                f"{', '.join(unsupported[:10])}. Supported inputs: FLAC, MP3, M4A, Opus, AAC, WAV."
            )
        return False, (
            "Unsupported manual import file(s): "
            f"{', '.join(unsupported[:10])}. Only FLAC and MP3 are allowed unless "
            "AUDIO_MANUAL_IMPORT_CONVERT_TO_MP3=true."
        )

    return True, "Manual import files allowed"


def _convert_manual_import_files_to_mp3(source_dir: Path) -> None:
    """Convert lossy input files to MP3 in place before metadata tagging."""
    if not cfg.manual_import_convert_to_mp3:
        return

    for file_path in sorted(source_dir.rglob("*")):
        if not file_path.is_file():
            continue
        suffix = file_path.suffix.lower()
        if suffix not in {".m4a", ".opus", ".aac", ".wav"}:
            continue

        target_path = file_path.with_suffix(".mp3")
        if target_path.exists() and target_path != file_path:
            base = file_path.with_suffix("")
            target_path = base.with_name(f"{base.name}_{int(time.time() * 1000000)}.mp3")

        log.info(f"Converting manual import audio: {file_path} -> {target_path}")
        result = subprocess.run(
            [
                "ffmpeg",
                "-y",
                "-i",
                str(file_path),
                "-vn",
                "-c:a",
                "libmp3lame",
                "-q:a",
                "2",
                str(target_path),
            ],
            capture_output=True,
            text=True,
            timeout=180,
        )
        if result.returncode != 0:
            stderr = (result.stderr or result.stdout or "").strip()
            raise RuntimeError(
                f"Failed to convert {file_path} to MP3: {stderr or 'ffmpeg returned a non-zero exit code'}"
            )

        file_path.unlink(missing_ok=True)


def import_manual_album(
    source_dir: Path,
    release_group_foreign_id: str,
    release_foreign_id: str = "",
) -> tuple[bool, str]:
    """Tag a user-supplied album (e.g. a CD rip) that isn't available on
    Deezer, in place, with the same MusicBrainz tagging, ReplayGain, and
    Beets enrichment as a normal deemix download.

    DEEZER_ALBUM_ID is set to cfg.manual_import_deezer_sentinel ("None" by
    default) instead of a real Deezer ID, so these files stay identifiable as
    manually-imported later. DATE_DOWNLOADED is set to the current time.

    This does NOT move or import the files anywhere - it only tags
    source_dir's contents in place. The caller (the shared AutoImport
    pre-move hook) is responsible for moving the tagged folder into Lidarr's
    watched import path afterward, exactly as it does for Radarr/Sonarr.

    Returns (success, message).
    """
    if not source_dir.is_dir():
        return False, f"Source folder not found: {source_dir}"

    ok, message = _validate_manual_import_files(source_dir)
    if not ok:
        return False, message

    if cfg.manual_import_convert_to_mp3:
        try:
            _convert_manual_import_files_to_mp3(source_dir)
        except Exception as exc:  # noqa: BLE001  # pragma: no cover - exercised via ffmpeg failure in real environments
            return False, f"Manual import conversion failed: {exc}"

    audio_files = [f for f in source_dir.rglob("*") if f.is_file() and f.suffix.lower() in {".flac", ".mp3"}]
    if not audio_files:
        return False, f"No supported audio files found in {source_dir} after validation"

    album_ids = get_album_ids_by_release_group(release_group_foreign_id)
    if not album_ids:
        return (
            False,
            f"No Lidarr album found for release group {release_group_foreign_id}",
        )
    if len(album_ids) > 1:
        log.warning(f"Multiple Lidarr albums matched release group {release_group_foreign_id}; using the first")
    album_id = album_ids[0]

    album_data = get_album_data(album_id)
    if album_data is None:
        return False, f"Could not fetch Lidarr album data for album {album_id}"

    artist_data = album_data.get("artist", {})
    artist_name = artist_data.get("artistName", "")
    artist_foreign_id = artist_data.get("foreignArtistId", "")
    album_title = album_data.get("title", "")
    album_foreign_id = album_data.get("foreignAlbumId", "") or release_group_foreign_id

    releases = album_data.get("releases", [])
    if not isinstance(releases, list) or not releases:
        return False, f"Lidarr album {album_id} has no releases"

    if release_foreign_id:
        release_json = next(
            (r for r in releases if r.get("foreignReleaseId") == release_foreign_id),
            None,
        )
        if release_json is None:
            return (
                False,
                f"Release {release_foreign_id} not found on Lidarr album {album_id}",
            )
    else:
        release_json = next((r for r in releases if r.get("monitored")), releases[0])
        release_foreign_id = release_json.get("foreignReleaseId", "")

    # Flatten any disc subfolders in place, then tag in place - the files
    # stay right where the caller found them; nothing is copied or moved.
    consolidate_files(source_dir)
    downloaded_timestamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    _tag_and_enrich(
        source_dir,
        artist_name,
        artist_foreign_id,
        album_title,
        release_foreign_id,
        album_foreign_id,
        cfg.manual_import_deezer_sentinel,
        downloaded_timestamp,
    )

    return True, f'Tagged "{album_title}" by "{artist_name}" in {source_dir}'


def _remove_from_priority_file(entry: str) -> None:
    """Remove a line from the priority file matching the given entry."""
    if not cfg.priority_file or not Path(cfg.priority_file).is_file():
        return
    try:
        path = Path(cfg.priority_file)
        lines = path.read_text().splitlines()
        # Compare with inline comments stripped, same as process_priority_list parsing
        path.write_text("\n".join(line for line in lines if line.split("#", 1)[0].strip() != entry) + "\n")
    except OSError:
        pass


def _write_result_file(
    album_id: str,
    artist_name: str,
    album_title: str,
    album_foreign_id: str,
    result: MatchResult,
) -> None:
    if not cfg.result_file_name:
        return
    out_file = cfg.work_path / cfg.result_file_name
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
    status = "Matched" if result.matched else "No match"

    if not out_file.exists():
        out_file.write_text(
            "# Download Match History\n\n"
            "| Timestamp | Artist | Album | Album Id | Release Group Id | Result | Release Id | Deezer Id |\n"
            "|-----------|--------|-------|----------|------------------|--------|------------|-----------|\n"
        )
    with open(out_file, "a") as f:
        f.write(
            f"| {timestamp} | {artist_name} | {album_title} | {album_id} "
            f"| {album_foreign_id} | {status} | {result.lidarr_release_foreign_id} | {result.deezer_album_id} |\n"
        )


def _upsert_missing_file(
    album_id: str,
    artist_name: str,
    album_title: str,
    album_foreign_id: str,
    reason: str,
) -> None:
    """Write/update a current missing-album reason record."""
    if not cfg.missing_result_file_name:
        return

    out_file = cfg.work_path / cfg.missing_result_file_name
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
    header = (
        "# Missing Album Reasons\n\n"
        "| Last Checked | Artist | Album | Album Id | Release Group Id | Reason |\n"
        "|--------------|--------|-------|----------|------------------|--------|\n"
    )

    rows: list[str] = []
    if out_file.exists():
        try:
            lines = out_file.read_text().splitlines()
            for line in lines:
                if not line.startswith("|"):
                    continue
                if "| Last Checked |" in line or "|--------------|" in line:
                    continue
                parts = [p.strip() for p in line.split("|")]
                if len(parts) < 7:
                    continue
                existing_album_id = parts[4]
                if existing_album_id and existing_album_id != album_id:
                    rows.append(line)
        except OSError:
            rows = []

    rows.append(f"| {timestamp} | {artist_name} | {album_title} | {album_id} | {album_foreign_id} | {reason} |")

    try:
        out_file.parent.mkdir(parents=True, exist_ok=True)
        content = header + "\n".join(rows) + "\n"
        out_file.write_text(content)
    except OSError:
        pass


def _remove_from_missing_file(album_id: str) -> None:
    """Remove an album from missing reasons after it matches."""
    if not cfg.missing_result_file_name:
        return

    out_file = cfg.work_path / cfg.missing_result_file_name
    if not out_file.exists():
        return

    try:
        lines = out_file.read_text().splitlines()
    except OSError:
        return

    kept: list[str] = []
    for line in lines:
        if not line.startswith("|"):
            kept.append(line)
            continue
        if "| Last Checked |" in line or "|--------------|" in line:
            kept.append(line)
            continue
        parts = [p.strip() for p in line.split("|")]
        if len(parts) < 7:
            kept.append(line)
            continue
        existing_album_id = parts[4]
        if existing_album_id != album_id:
            kept.append(line)

    with contextlib.suppress(OSError):
        out_file.write_text("\n".join(kept).rstrip() + "\n")


# ─── Processing loops ─────────────────────────────────────────────────────


_UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.IGNORECASE)


def _is_valid_uuid(value: str) -> bool:
    """Check if a string is a valid UUID format."""
    return bool(_UUID_RE.match(value))


def _resolve_priority_entries(entries: list[str]) -> list[tuple[str, str]]:
    """Resolve priority file entries to (album_id, original_entry) tuples.

    Supported formats:
      - Plain numeric Lidarr album ID (e.g. "123")
      - mb_rg:<uuid>  — MusicBrainz release group ID
      - mb_artist:<uuid> — All wanted albums for a MusicBrainz artist
    """
    results: list[tuple[str, str]] = []
    seen: set[str] = set()
    for entry in entries:
        if entry.startswith("mb_rg:"):
            foreign_id = entry[len("mb_rg:") :].strip()
            if not _is_valid_uuid(foreign_id):
                log.warning(f"Invalid UUID in priority entry: {entry}")
                continue
            resolved = get_album_ids_by_release_group(foreign_id)
            if resolved:
                log.debug(f"Resolved {entry} -> album IDs {resolved}")
                for aid in resolved:
                    if aid not in seen:
                        seen.add(aid)
                        results.append((aid, entry))
            else:
                log.warning(f"Could not resolve {entry} to any Lidarr album")
        elif entry.startswith("mb_artist:"):
            foreign_id = entry[len("mb_artist:") :].strip()
            if not _is_valid_uuid(foreign_id):
                log.warning(f"Invalid UUID in priority entry: {entry}")
                continue
            resolved = get_album_ids_by_artist(foreign_id)
            if resolved:
                log.debug(f"Resolved {entry} -> {len(resolved)} album(s)")
                for aid in resolved:
                    if aid not in seen:
                        seen.add(aid)
                        results.append((aid, entry))
            else:
                log.info(f"No wanted albums found for {entry} (all may already be downloaded)")
        else:
            if entry not in seen:
                seen.add(entry)
                results.append((entry, entry))
    return results


def process_priority_list(failed_albums: set[str], daily_tracker: DailyLimitTracker, arl_token: str) -> None:
    """Process user-provided priority album list."""
    if not cfg.priority_file or not Path(cfg.priority_file).is_file():
        return

    lines = Path(cfg.priority_file).read_text().splitlines()
    raw_entries: list[str] = []
    for line in lines:
        # Strip inline comments (e.g. "mb_rg:uuid # My Album")
        entry = line.split("#", 1)[0].strip()
        if entry:
            raw_entries.append(entry)
    if not raw_entries:
        return

    resolved = _resolve_priority_entries(raw_entries)
    if not resolved:
        return

    log.info(f"Processing {len(resolved)} priority album(s)")
    for album_id, original_entry in resolved:
        if not cfg.priority_exempt_from_limit and daily_tracker.is_limit_reached():
            log.info("Daily limit reached; pausing priority processing")
            break
        if original_entry != album_id:
            log.debug(f"Processing album {album_id} (from priority entry: {original_entry})")
        search_and_download(
            album_id,
            failed_albums,
            daily_tracker,
            arl_token,
            priority_entry=original_entry,
        )


def process_wanted_list(
    list_type: str,
    failed_albums: set[str],
    daily_tracker: DailyLimitTracker,
    arl_token: str,
) -> None:
    """Process Lidarr wanted list (missing or cutoff)."""
    response = get_wanted_albums(list_type, page=1, page_size=1)
    total_records = response.get("totalRecords", 0)
    log.debug(f"Found {total_records} {list_type} albums")
    if total_records < 1:
        return

    notfound_ids = _get_marker_ids(cfg.notfound_dir)
    downloaded_ids = _get_marker_ids(cfg.downloaded_dir)

    page_size = 1000
    total_pages = (total_records + page_size - 1) // page_size

    for page in range(1, total_pages + 1):
        response = get_wanted_albums(list_type, page=page, page_size=page_size)
        album_ids = list(set(str(r.get("id", "")) for r in response.get("records", []) if r.get("id")))
        album_ids = [aid for aid in album_ids if aid not in notfound_ids and aid not in downloaded_ids]

        if not album_ids:
            continue

        log.info(f"Processing {len(album_ids)} {list_type} albums")
        for idx, album_id in enumerate(album_ids, 1):
            if idx % 25 == 0:
                log.info(f"Progress: {idx}/{len(album_ids)} {list_type} albums processed")
            if daily_tracker.is_limit_reached():
                log.info(f"Daily limit reached; stopping {list_type} processing")
                return
            search_and_download(album_id, failed_albums, daily_tracker, arl_token)

    log.info(f"Completed processing {list_type} albums")


# ─── Manual import (user-supplied CD rips) ─────────────────────────────────
#
# Reuses shared.python.autoimport (the same mechanism as Radarr/Sonarr's
# AutoImport): scan a drop directory for marked folders, match by resource
# path, then move matched folders into Lidarr's watched import path so its
# own DownloadedAlbumsScan/download-client polling picks them up - same as
# Radarr/Sonarr, no explicit Lidarr API call needed.
#
# The one structural difference: Lidarr's Album resource has no folder path
# (only Artist does), so matching can only resolve to an ARTIST. The release
# MBID needed to pick a specific album still has to travel in the folder
# name, via parse_folder_name() below, for the pre-move hook to use.


def parse_manual_import_folder_name(raw_target_name: str) -> tuple[str, str]:
    """Split '<artist folder name>--<release-group-mbid>[--<release-mbid>]'
    into (match_key, hook_arg): match_key is the artist folder name (matched
    against Lidarr's known artist paths), hook_arg is everything after it
    (passed to the pre-move hook to resolve/tag the specific album)."""
    parts = raw_target_name.split("--", 1)
    match_key = parts[0].strip()
    hook_arg = parts[1].strip() if len(parts) > 1 else ""
    return match_key, hook_arg


def manual_import_pre_move_hook(import_dir: Path, hook_arg: str) -> bool:
    """AutoImport pre-move hook: tags the matched folder in place before it's
    moved into Lidarr's watched import path. Returns False (abort the move)
    if hook_arg doesn't contain a usable release-group MBID or tagging fails."""
    parts = hook_arg.split("--", 1)
    release_group_foreign_id = parts[0].strip()
    release_foreign_id = parts[1].strip() if len(parts) > 1 else ""

    if not _is_valid_uuid(release_group_foreign_id):
        log.warning(f"Manual import: '{hook_arg}' does not contain a valid MusicBrainz release group ID")
        with contextlib.suppress(OSError):
            (import_dir / "IMPORT_STATUS.txt").write_text(
                f"'{hook_arg}' does not contain a valid MusicBrainz release group ID.\n"
                "Expected folder name: <artist folder name>--<release-group-mbid>[--<release-mbid>]",
                encoding="utf-8",
            )
        return False

    success, message = import_manual_album(import_dir, release_group_foreign_id, release_foreign_id)
    if success:
        log.info(f"Manual import: {message}")
    else:
        log.warning(f"Manual import: {message}")
        with contextlib.suppress(OSError):
            (import_dir / "IMPORT_STATUS.txt").write_text(message, encoding="utf-8")
    return success


# ─── Main ─────────────────────────────────────────────────────────────────


def main() -> None:
    """Main loop for the DeemixDownloader service."""
    log.info("Starting DeemixDownloader")

    init_state()
    verify_arr_api_access()
    add_download_client()

    arl_token = setup_deemix()
    setup_beets()
    setup_working_dirs()

    log.info("Lift off in 5...")
    time.sleep(5)

    daily_tracker = DailyLimitTracker()

    while True:
        try:
            # Re-read ARL token in case ARLChecker has refreshed it
            arl_token = cfg.deemix_arl_file.read_text(encoding="utf-8").strip().strip('\r\n"')

            folder_cleaner()
            prune_cache()

            failed_albums = _get_failed_albums()

            limit_reached = daily_tracker.is_limit_reached()

            # Priority list runs even when limit is reached if exempt
            if not limit_reached or cfg.priority_exempt_from_limit:
                process_priority_list(failed_albums, daily_tracker, arl_token)

            if limit_reached:
                log.info("Daily download limit reached; skipping wanted list processing")
            elif not cfg.priority_only:
                process_wanted_list("missing", failed_albums, daily_tracker, arl_token)
                process_wanted_list("cutoff", failed_albums, daily_tracker, arl_token)
        except Exception as e:  # noqa: BLE001 - one bad pass must not stop the service
            log.error(f"Unexpected error in main loop: {e}")

        if cfg.interval.lower() == "none" or cfg.interval_seconds == 0:
            log.info("AUDIO_INTERVAL is 'none', exiting after single run")
            break

        log.info(f"Sleeping for {cfg.interval}...")
        time.sleep(cfg.interval_seconds)


def indexer_main() -> None:
    """Run the authenticated Newznab indexer and quota-aware grab worker."""
    from .indexer_bridge import build_bridge_from_environment

    log.info("Starting Lidarr Deemix Indexer")
    init_state()
    verify_arr_api_access()
    arl_token = setup_deemix()
    setup_beets()
    setup_working_dirs()

    def download(release: dict, on_download_complete: Callable[[], None]) -> bool:
        token = cfg.deemix_arl_file.read_text(encoding="utf-8").strip().strip('\r\n"')
        return download_indexer_release(release, on_download_complete, token or arl_token)

    bridge = build_bridge_from_environment(search_indexer_releases, download)
    bridge.serve(bridge.bind_host, bridge.bind_port)


if __name__ == "__main__":
    main()
