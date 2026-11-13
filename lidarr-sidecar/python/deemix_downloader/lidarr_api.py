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
import time
from pathlib import Path
from typing import Any
from urllib.parse import quote_plus

# Add the app root so shared modules can be found
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "../..")))

from shared.python.arrapi import (
    arr_api_request,
)
from shared.python.state import get_state

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

    payload = json.dumps(
        {
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
        }
    )

    arr_api_request("POST", "downloadclient", payload)
    log.debug(f"Successfully added {cfg.download_client_name} download client")


def notify_lidarr_import(import_path: str) -> None:
    """Trigger Lidarr's DownloadedAlbumsScan for a specific path."""
    payload = json.dumps({"name": "DownloadedAlbumsScan", "path": import_path})
    arr_api_request("POST", "command", payload)
    log.debug(f"Sent import notification to Lidarr for: {import_path}")


def scan_import_and_verify(import_path: str, album_id: int | str) -> tuple[bool, list[str]]:
    """Run DownloadedAlbumsScan and confirm it actually registered track files.

    Unlike notify_lidarr_import (fire-and-forget), this polls the command to
    completion and checks the album's track-file count increased, so a scan that
    imports nothing is reported as a failure instead of a false success.
    """
    before_count = _album_trackfile_count(album_id)
    payload = json.dumps({"name": "DownloadedAlbumsScan", "path": import_path})
    arr_api_request("POST", "command", payload)
    response = get_state("arrApiResponse")
    command_id = response.get("id") if isinstance(response, dict) else None
    if command_id is None:
        return False, ["Lidarr did not return a command id for DownloadedAlbumsScan"]

    timeout = int(os.environ.get("ARR_COMMAND_WAIT_TIMEOUT", "300"))
    ok, detail = _await_command(int(command_id), timeout)
    if not ok:
        return False, [detail]

    after_count = _album_trackfile_count(album_id)
    if after_count <= before_count:
        return False, [
            "DownloadedAlbumsScan completed but no new track files were "
            f"registered (before={before_count}, after={after_count})"
        ]
    return True, []


def _collect_rejections(items: list[Any]) -> list[str]:
    """Flatten per-item Lidarr rejection reasons into readable strings."""
    rejections: list[str] = []
    for item in items:
        if not isinstance(item, dict):
            continue
        path_val = item.get("path") or item.get("name") or "item"
        for rej in item.get("rejections", []) or []:
            reason = rej.get("reason") if isinstance(rej, dict) else str(rej)
            rejections.append(f"{path_val}: {reason}")
    return rejections


def _extract_track_ids(item: dict[str, Any]) -> list[int]:
    """Pull the matched Lidarr track ids out of a manual-import item."""
    track_ids: list[int] = []
    for track in item.get("tracks", []) or []:
        if isinstance(track, dict) and track.get("id") is not None:
            track_ids.append(int(track["id"]))
    return track_ids


def _has_only_forced_album_score_rejections(
    items: list[Any],
    artist_id: int | str,
    album_id: int | str,
    release_id: int | str,
    *,
    allow_release_not_requested: bool = False,
) -> bool:
    """Allow Lidarr's album-score rejection only when its forced IDs and track mappings remain exact."""
    expected_artist_id, expected_album_id, expected_release_id = (
        int(artist_id),
        int(album_id),
        int(release_id),
    )
    importable_items = [item for item in items if isinstance(item, dict) and not item.get("additionalFile")]
    if not importable_items:
        return False

    for item in importable_items:
        artist = item.get("artist")
        album = item.get("album")
        if (
            not isinstance(artist, dict)
            or artist.get("id") != expected_artist_id
            or not isinstance(album, dict)
            or album.get("id") != expected_album_id
            or item.get("albumReleaseId") != expected_release_id
        ):
            return False

        tracks = item.get("tracks")
        track_ids = _extract_track_ids(item)
        if not isinstance(tracks, list) or not track_ids:
            return False
        if any(
            isinstance(track, dict) and track.get("albumId") is not None and track.get("albumId") != expected_album_id
            for track in tracks
        ):
            return False

        for rejection in item.get("rejections", []) or []:
            reason = rejection.get("reason", "") if isinstance(rejection, dict) else str(rejection)
            if not reason.startswith("Album match is not close enough:") and not (
                allow_release_not_requested and reason == "Album release not requested"
            ):
                return False

    return True


def _album_trackfile_count(album_id: int | str) -> int:
    """Return how many track files Lidarr currently has registered for an album."""
    arr_api_request("GET", f"trackfile?albumId={album_id}")
    response = get_state("arrApiResponse")
    return len(response) if isinstance(response, list) else 0


def _await_command(command_id: int, timeout: int) -> tuple[bool, str]:
    """Poll a Lidarr command to a terminal state; return (succeeded, detail)."""
    terminal = {"completed", "failed", "aborted", "cancelled", "orphaned"}
    deadline = time.monotonic() + timeout
    while True:
        arr_api_request("GET", f"command/{command_id}")
        command = get_state("arrApiResponse")
        status = command.get("status") if isinstance(command, dict) else None
        if status in terminal:
            if status == "completed":
                return True, "completed"
            detail = ""
            if isinstance(command, dict):
                detail = command.get("exception") or command.get("message") or ""
            return False, f"command {status}: {detail}".strip()
        if time.monotonic() >= deadline:
            return False, f"command did not finish within {timeout}s"
        time.sleep(2)


def manual_import_release(
    import_path: str,
    artist_id: int | str,
    album_id: int | str,
    release_id: int | str,
    *,
    strict: bool = False,
) -> tuple[bool, list[str]]:
    """Run a deterministic manual import by forcing artist/album/release for each file.

    The GET /manualimport preview and the POST /manualimport reprocess only
    recompute track matching and rejections; neither imports anything. The
    actual import must be queued as a ManualImport *command*, so after a clean
    reprocess we submit that command and confirm Lidarr registered track files.
    """
    folder = quote_plus(import_path)
    path = f"manualimport?folder={folder}&artistId={artist_id}&filterExistingFiles=false&replaceExistingFiles=true"
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
        updates.append(
            {
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
            }
        )

    if not updates:
        return False, ["No valid manual import updates could be generated"]

    # Reprocess under the forced artist/album/release to surface rejections and
    # to obtain the per-file track mapping needed by the ManualImport command.
    arr_api_request("POST", "manualimport", json.dumps(updates))
    post_response = get_state("arrApiResponse")
    try:
        results = json.loads(post_response) if isinstance(post_response, str) else post_response
    except (json.JSONDecodeError, TypeError):
        results = []

    if not isinstance(results, list):
        return False, ["Unexpected manual import response from Lidarr"]

    rejections = _collect_rejections(results)
    if rejections and not _has_only_forced_album_score_rejections(
        results, artist_id, album_id, release_id, allow_release_not_requested=strict
    ):
        return False, rejections
    if rejections:
        log.warning(
            "Lidarr rejected its album-score or release-selection preflight, but the forced artist, album, "
            "release, and track IDs are intact; proceeding with the ManualImport command"
        )

    if strict:
        preview_paths = [
            item.get("path") for item in items if isinstance(item, dict) and not item.get("additionalFile")
        ]
        result_paths = [
            item.get("path") for item in results if isinstance(item, dict) and not item.get("additionalFile")
        ]
        if (
            not preview_paths
            or any(not isinstance(path, str) or not path for path in preview_paths + result_paths)
            or any(not Path(path).resolve().is_relative_to(Path(import_path).resolve()) for path in preview_paths)
            or len(set(preview_paths)) != len(preview_paths)
            or len(set(result_paths)) != len(result_paths)
            or set(preview_paths) != set(result_paths)
        ):
            return False, ["Lidarr did not reprocess every previewed audio file exactly once"]

    return submit_manual_import(results, artist_id, album_id, release_id, strict=strict)


def _strict_release_tracks(
    artist_id: int | str, album_id: int | str, release_id: int | str
) -> tuple[dict[int, int], str]:
    arr_api_request("GET", f"track?albumId={int(album_id)}&albumReleaseId={int(release_id)}")
    response = get_state("arrApiResponse")
    if not isinstance(response, list) or not response:
        return {}, "Lidarr did not return tracks for the selected release"
    tracks: dict[int, int] = {}
    for track in response:
        if (
            not isinstance(track, dict)
            or track.get("artistId") != int(artist_id)
            or track.get("albumId") != int(album_id)
            or type(track.get("id")) is not int
            or track["id"] <= 0
            or type(track.get("trackFileId")) is not int
            or track["trackFileId"] < 0
            or track["id"] in tracks
        ):
            return {}, "Lidarr returned invalid tracks for the selected release"
        tracks[track["id"]] = track["trackFileId"]
    return tracks, ""


def _strict_album_file_ids(album_id: int | str) -> tuple[set[int], str]:
    arr_api_request("GET", f"trackfile?albumId={int(album_id)}")
    response = get_state("arrApiResponse")
    if not isinstance(response, list):
        return set(), "Lidarr returned an invalid album track-file list"
    ids: set[int] = set()
    for item in response:
        if not isinstance(item, dict) or type(item.get("id")) is not int or item["id"] <= 0 or item["id"] in ids:
            return set(), "Lidarr returned an invalid album track-file list"
        ids.add(item["id"])
    return ids, ""


def submit_manual_import(
    items: list[dict[str, Any]],
    artist_id: int | str,
    album_id: int | str,
    release_id: int | str,
    import_mode: str = "move",
    *,
    strict: bool = False,
) -> tuple[bool, list[str]]:
    """Queue a ManualImport command for already-identified items and confirm it.

    `items` must be the reprocessed manual-import items (each carrying its
    matched `tracks`). Returns (imported, rejections); `imported` is only True
    once Lidarr reports the command completed and track files are registered.
    """
    files: list[dict[str, Any]] = []
    mapped_track_ids: list[int] = []
    for item in items:
        if not isinstance(item, dict) or item.get("additionalFile"):
            continue
        tracks = item.get("tracks")
        if strict and (
            not isinstance(item.get("artist"), dict)
            or item["artist"].get("id") != int(artist_id)
            or not isinstance(item.get("album"), dict)
            or item["album"].get("id") != int(album_id)
            or item.get("albumReleaseId") != int(release_id)
            or not isinstance(tracks, list)
            or not tracks
            or any(
                not isinstance(track, dict)
                or type(track.get("id")) is not int
                or track["id"] <= 0
                or (track.get("albumId") is not None and track["albumId"] != int(album_id))
                for track in tracks
            )
        ):
            return False, ["Lidarr did not preserve the forced artist, album, release and track mappings"]
        track_ids = _extract_track_ids(item)
        if not track_ids:
            continue
        mapped_track_ids.extend(track_ids)
        files.append(
            {
                "path": item.get("path", ""),
                "artistId": int(artist_id),
                "albumId": int(album_id),
                "albumReleaseId": int(release_id),
                "trackIds": track_ids,
                "quality": item.get("quality"),
                "releaseGroup": item.get("releaseGroup", ""),
                "indexerFlags": item.get("indexerFlags", 0),
                "downloadId": item.get("downloadId", "") or "",
                "disableReleaseSwitching": True,
            }
        )

    if not files:
        return False, ["No audio files could be mapped to tracks for manual import"]

    if strict:
        expected_tracks, error = _strict_release_tracks(artist_id, album_id, release_id)
        if error:
            return False, [error]
        if len(mapped_track_ids) != len(set(mapped_track_ids)) or set(mapped_track_ids) != set(expected_tracks):
            return False, ["The mapped files do not cover the selected release's tracks exactly once"]
        before_files, error = _strict_album_file_ids(album_id)
        if error:
            return False, [error]
    else:
        before_count = _album_trackfile_count(album_id)

    command = {
        "name": "ManualImport",
        "importMode": import_mode,
        "replaceExistingFiles": True,
        "files": files,
    }
    arr_api_request("POST", "command", json.dumps(command))
    command_response = get_state("arrApiResponse")
    command_id = command_response.get("id") if isinstance(command_response, dict) else None
    if command_id is None:
        return False, ["Lidarr did not return a command id for ManualImport"]

    timeout = int(os.environ.get("ARR_COMMAND_WAIT_TIMEOUT", "300"))
    ok, detail = _await_command(int(command_id), timeout)
    if not ok:
        return False, [detail]

    if strict:
        imported_tracks, error = _strict_release_tracks(artist_id, album_id, release_id)
        if error:
            return False, [error]
        after_files, error = _strict_album_file_ids(album_id)
        if error:
            return False, [error]
        if set(imported_tracks) != set(expected_tracks) or any(
            not file_id or file_id not in after_files or file_id in before_files for file_id in imported_tracks.values()
        ):
            return False, ["ManualImport completed but not all selected release tracks have new registered files"]
        return True, []

    after_count = _album_trackfile_count(album_id)
    if after_count <= before_count:
        return False, [
            "ManualImport command completed but no new track files were "
            f"registered (before={before_count}, after={after_count})"
        ]

    return True, []


def remove_lidarr_queue_items(download_ids: list[str] | tuple[str, ...]) -> int:
    """Remove successfully imported NZBGet items from Lidarr's tracked queue."""
    target_ids = {str(download_id) for download_id in download_ids if download_id}
    if not target_ids:
        log.warning("Cannot clear imported Deemix queue items without Lidarr download IDs")
        return 0

    queue_ids: set[int] = set()
    page = 1
    requested_page_size = 1000
    while True:
        arr_api_request(
            "GET",
            f"queue?page={page}&pageSize={requested_page_size}&includeUnknownArtistItems=true",
        )
        response = get_state("arrApiResponse")
        try:
            response = json.loads(response) if isinstance(response, str) else response
        except json.JSONDecodeError as exc:
            raise RuntimeError("Lidarr returned invalid queue JSON while clearing an imported item") from exc
        if not isinstance(response, dict) or not isinstance(response.get("records"), list):
            raise RuntimeError("Lidarr returned an invalid queue response while clearing an imported item")

        records = response["records"]
        for item in records:
            if not isinstance(item, dict) or str(item.get("downloadId") or "") not in target_ids:
                continue
            try:
                queue_id = int(item["id"])
            except (KeyError, TypeError, ValueError) as exc:
                raise RuntimeError("Lidarr returned a queue item without a valid ID") from exc
            if queue_id <= 0:
                raise RuntimeError("Lidarr returned a queue item without a valid ID")
            queue_ids.add(queue_id)

        try:
            total_records = int(response.get("totalRecords", len(records)))
            page_size = int(response.get("pageSize", requested_page_size))
        except (TypeError, ValueError) as exc:
            raise RuntimeError("Lidarr returned invalid queue pagination metadata") from exc
        if not records or page_size <= 0 or len(records) < page_size or page * page_size >= total_records:
            break
        page += 1

    if not queue_ids:
        log.warning("No Lidarr queue item matched the imported Deemix download IDs")
        return 0

    for queue_id in sorted(queue_ids):
        arr_api_request("DELETE", f"queue/{queue_id}?removeFromClient=true&blocklist=false")

    log.info(f"Removed {len(queue_ids)} imported Deemix item(s) from Lidarr's queue")
    return len(queue_ids)


def get_wanted_albums(list_type: str, page: int = 1, page_size: int = 1000, include_artist: bool = False) -> dict:
    """
    Fetch a page of wanted albums from Lidarr.
    list_type: "missing" or "cutoff"
    include_artist: Lidarr omits the nested "artist" object (foreignArtistId etc.)
    unless includeArtist=true is passed, since it defaults to false server-side.
    Returns the full API response dict.
    """
    path = (
        f"wanted/{list_type}?page={page}&pagesize={page_size}"
        f"&sortKey=releaseDate&sortDirection=descending"
        f"&includeArtist={'true' if include_artist else 'false'}"
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

    Checks both missing and cutoff unmet lists, paginating like process_wanted_list
    so a large wanted list can't be pulled into memory in one huge response.
    """
    page_size = 1000
    album_ids: list[str] = []
    for list_type in ("missing", "cutoff"):
        page = 1
        total_pages = 1
        while page <= total_pages:
            response = get_wanted_albums(list_type, page=page, page_size=page_size, include_artist=True)
            total_records = response.get("totalRecords", 0) if isinstance(response, dict) else 0
            total_pages = max(1, (total_records + page_size - 1) // page_size)
            records = response.get("records", []) if isinstance(response, dict) else []
            album_ids.extend(
                str(r["id"]) for r in records if r.get("artist", {}).get("foreignArtistId") == foreign_artist_id
            )
            page += 1
    return album_ids
