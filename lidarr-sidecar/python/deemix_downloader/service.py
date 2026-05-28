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

import json
import os
import re
import shutil
import sys
import time
from datetime import date
from pathlib import Path

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "../..")))

from shared.python.arrapi import verify_arr_api_access
from shared.python.state import init_state

from .config import cfg
from .download import (
    AUDIO_EXTENSIONS,
    apply_beets,
    apply_replaygain,
    clean_staging,
    consolidate_files,
    count_audio_files,
    download_with_deemix,
    move_to_import,
    prune_cache,
    setup_working_dirs,
    tag_flac_artist,
    tag_flac_musicbrainz,
    tag_mp3_mutagen,
    verify_flac,
)
from .lidarr_api import (
    add_download_client,
    get_album_data,
    get_album_ids_by_artist,
    get_album_ids_by_release_group,
    get_wanted_albums,
    notify_lidarr_import,
)
from .logging import log
from .matching import MatchResult, ReleaseCandidate, find_best_match
from .musicbrainz_api import fetch_musicbrainz_release
from .string_utils import calculate_priority, normalize_string, remove_punctuation

# ─── Constants ─────────────────────────────────────────────────────────

DEEMIX_DIR = Path("/tmp/deemix")
DEEMIX_CONFIG_PATH = DEEMIX_DIR / "config" / "config.json"
BEETS_DIR = Path("/tmp/beets")
BEETS_CONFIG_PATH = BEETS_DIR / "beets.yaml"

# Pre-compiled keyword patterns (built once from config)
_COMMENTARY_RE = re.compile(
    "|".join(re.escape(k) for k in cfg.commentary_keywords), re.IGNORECASE
) if cfg.commentary_keywords else None
_INSTRUMENTAL_RE = re.compile(
    "|".join(re.escape(k) for k in cfg.instrumental_keywords), re.IGNORECASE
) if cfg.instrumental_keywords else None


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
                ["yq", "eval-all", "select(fileIndex == 0) * select(fileIndex == 1)",
                 str(BEETS_CONFIG_PATH), "-"],
                input=content, capture_output=True, text=True,
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

        # Check commentary
        contains_commentary = bool(
            _COMMENTARY_RE and (
                _COMMENTARY_RE.search(title) or _COMMENTARY_RE.search(disambiguation)
            )
        )

        # Check instrumental
        instrumental = bool(
            _INSTRUMENTAL_RE and (
                _INSTRUMENTAL_RE.search(title) or _INSTRUMENTAL_RE.search(disambiguation)
            )
        )

        candidates.append(ReleaseCandidate(
            title=title,
            disambiguation=disambiguation,
            foreign_id=foreign_release_id,
            track_count=track_count,
            deezer_album_id=deezer_album_id,
            release_status=release_status,
            year=year,
            format_priority=format_priority,
            country_priority=country_priority,
            contains_commentary=contains_commentary,
            instrumental=instrumental,
        ))

    return candidates


# ─── Search and download ─────────────────────────────────────────────────


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
    album_release_year = album_release_date[:4] if album_release_date else ""

    # Check if not yet released
    if album_release_date:
        release_clean = re.sub(r"[^0-9]", "", album_release_date[:10])
        today_clean = time.strftime("%Y%m%d")
        if release_clean and today_clean < release_clean:
            log.debug(f"Album \"{album_title}\" not yet released, skipping")
            return

    # Check existing markers
    marker = f"{album_id}--{artist_foreign_id}--{album_foreign_id}"
    if cfg.notfound_dir.is_dir() and (cfg.notfound_dir / marker).exists():
        log.debug(f"Album \"{album_title}\" previously marked not found, skipping")
        return
    if cfg.downloaded_dir.is_dir() and (cfg.downloaded_dir / marker).exists():
        log.debug(f"Album \"{album_title}\" previously downloaded, skipping")
        return

    log.info(f"Searching for album \"{album_title}\" by \"{artist_name}\"")

    # Build release candidates
    candidates = _build_candidates(album_data, album_release_year)

    # Find match
    result = find_best_match(candidates, album_title, failed_albums)

    # Write result file
    _write_result_file(album_id, artist_name, album_title, album_foreign_id, result)

    if result.matched:
        success = _download_album(
            result, artist_name, artist_foreign_id,
            album_title_raw, album_foreign_id, album_id, arl_token,
            priority_entry=priority_entry,
        )
        if success:
            daily_tracker.increment()
    else:
        log.info(f"No match: {result.reason}")
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


def _download_album(
    result: MatchResult,
    artist_name: str,
    artist_foreign_id: str,
    album_title: str,
    album_foreign_id: str,
    album_id: str,
    arl_token: str,
    priority_entry: str = "",
) -> bool:
    """Download, tag, and import an album. Returns True on success."""
    deezer_album_id = result.deezer_album_id
    deezer_title = result.deezer_title
    deezer_track_count = result.deezer_track_count
    release_year = result.deezer_year

    # Check previously failed
    if (cfg.failed_dir / deezer_album_id).exists():
        log.warning(f"Album \"{deezer_title}\" previously failed, skipping")
        return False

    if not cfg.shared_lidarr_path.is_dir():
        log.error(f"Shared Lidarr path not found: {cfg.shared_lidarr_path}")
        return False

    log.info(f"Downloading: [{deezer_album_id}] {deezer_title} ({release_year})")

    # Download with retry
    quality = "flac"
    download_try = 0

    while True:
        download_try += 1

        if download_try >= cfg.download_attempt_threshold:
            if cfg.download_quality_fallback and quality == "flac":
                log.warning(f"Failed after {download_try} attempts, trying mp3 fallback")
                clean_staging()
                quality = "mp3"
                download_try = 0
            else:
                log.warning(f"Failed after {download_try} attempts, giving up")
                cfg.failed_dir.mkdir(parents=True, exist_ok=True)
                (cfg.failed_dir / deezer_album_id).touch()
                return False

        log.debug(f"Download attempt #{download_try}")
        clean_staging()
        download_with_deemix(deezer_album_id, arl_token, quality, DEEMIX_DIR)

        dl_count = count_audio_files(cfg.staging_dir)
        if dl_count <= 0:
            log.warning(f"No audio files on attempt #{download_try}")
            time.sleep(1)
            continue

        # Verify FLAC files
        for f in list(cfg.staging_dir.rglob("*.flac")):
            if not verify_flac(f):
                log.warning(f"FLAC verification failed: {f.name}, removing")
                f.unlink()

        final_count = count_audio_files(cfg.staging_dir)
        if final_count != deezer_track_count:
            log.warning(f"Expected {deezer_track_count} tracks, got {final_count}")
            time.sleep(1)
            continue

        break

    # Post-processing
    consolidate_files(cfg.staging_dir)

    release_foreign_id = result.lidarr_release_foreign_id

    # Tag with MusicBrainz info
    for f in cfg.staging_dir.iterdir():
        if not f.is_file():
            continue
        if f.suffix.lower() == ".flac":
            tag_flac_musicbrainz(f, album_title, release_foreign_id, album_foreign_id)
        elif f.suffix.lower() == ".mp3":
            tag_mp3_mutagen(f, album_title=album_title, release_id=release_foreign_id, release_group_id=album_foreign_id)

    # ReplayGain
    if cfg.apply_replaygain:
        apply_replaygain(cfg.staging_dir)

    # Beets
    if cfg.apply_beets:
        apply_beets(cfg.staging_dir, release_foreign_id, BEETS_CONFIG_PATH, BEETS_DIR)

    # Artist tags
    for f in cfg.staging_dir.iterdir():
        if not f.is_file():
            continue
        if f.suffix.lower() == ".flac":
            tag_flac_artist(f, artist_name, artist_foreign_id)
        elif f.suffix.lower() == ".mp3":
            tag_mp3_mutagen(f, artist_name=artist_name, artist_foreign_id=artist_foreign_id)

    # Move and import
    dest = move_to_import(artist_name, album_title, release_year, album_foreign_id)
    notify_lidarr_import(str(dest))

    # Mark downloaded
    marker = f"{album_id}--{artist_foreign_id}--{album_foreign_id}"
    cfg.downloaded_dir.mkdir(parents=True, exist_ok=True)
    (cfg.downloaded_dir / marker).touch()

    # Remove from priority file (use original entry if from a prefixed source)
    entry_to_remove = priority_entry if priority_entry else album_id
    # Don't remove mb_artist: entries since they represent multiple albums
    if not entry_to_remove.startswith("mb_artist:"):
        _remove_from_priority_file(entry_to_remove)

    log.info(f"Successfully downloaded \"{deezer_title}\"")
    clean_staging()
    return True


def _remove_from_priority_file(entry: str) -> None:
    """Remove a line from the priority file matching the given entry."""
    if not cfg.priority_file or not Path(cfg.priority_file).is_file():
        return
    try:
        path = Path(cfg.priority_file)
        lines = path.read_text().splitlines()
        path.write_text("\n".join(l for l in lines if l.strip() != entry) + "\n")
    except OSError:
        pass


def _write_result_file(
    album_id: str, artist_name: str, album_title: str,
    album_foreign_id: str, result: MatchResult,
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
        f.write(f"| {timestamp} | {artist_name} | {album_title} | {album_id} "
                f"| {album_foreign_id} | {status} | {result.lidarr_release_foreign_id} | {result.deezer_album_id} |\n")


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
            foreign_id = entry[len("mb_rg:"):].strip()
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
            foreign_id = entry[len("mb_artist:"):].strip()
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
                log.warning(f"Could not resolve {entry} to any wanted albums")
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
    raw_entries = [l.strip() for l in lines if l.strip() and not l.strip().startswith("#")]
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
        search_and_download(album_id, failed_albums, daily_tracker, arl_token, priority_entry=original_entry)


def process_wanted_list(
    list_type: str, failed_albums: set[str],
    daily_tracker: DailyLimitTracker, arl_token: str,
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

            if daily_tracker.is_limit_reached():
                log.info("Daily download limit reached; skipping processing")
            else:
                process_priority_list(failed_albums, daily_tracker, arl_token)
                if not cfg.priority_only:
                    process_wanted_list("missing", failed_albums, daily_tracker, arl_token)
                    process_wanted_list("cutoff", failed_albums, daily_tracker, arl_token)
        except Exception as e:
            log.error(f"Unexpected error in main loop: {e}")

        if cfg.interval.lower() == "none" or cfg.interval_seconds == 0:
            log.info("AUDIO_INTERVAL is 'none', exiting after single run")
            break

        log.info(f"Sleeping for {cfg.interval}...")
        time.sleep(cfg.interval_seconds)


if __name__ == "__main__":
    main()
