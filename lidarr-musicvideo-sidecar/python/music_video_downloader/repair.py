#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

"""Repair: bring the videos already in the library up to the current naming, NFO and poster.

For every video in a selected artist's folder whose NFO (or state) records its YouTube ID, the repair looks up
the upload once (title, date, channel, thumbnail; cached in state.json), and then:

- renames it (with its NFO, poster and subtitles) to the name the current rules give the upload title, in the
  artist folder the current rules give the artist (moving it out of a folder named the old way),
- rewrites its NFO (artist, year, studio, genres, MusicBrainz artist ID, lockdata),
- replaces a missing poster, or one the sidecar did not write, with the YouTube thumbnail.

Videos without a YouTube ID (added by hand) keep their name; they only follow the artist to a renamed folder.
Videos the current rules would no longer download, and renames that would overwrite another file, are listed in
VIDEO_STATE_DIR/repair-report.md, not deleted.
REPAIR_VERSION is bumped when the rules change, so every video is checked again (from the cache, no lookups).
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from pathlib import Path

from shared.python.logging_utils import info, warning

from . import library, musicbrainz, youtube
from .classify import classify
from .config import Config
from .state import State

REPAIR_VERSION = 1
META_FIELDS = ("title", "upload_date", "channel", "duration")


@dataclass
class RepairStats:
    checked: int = 0
    renamed: int = 0
    nfos: int = 0
    posters: int = 0
    lookups: int = 0
    failed: int = 0
    flagged: int = 0


@dataclass
class ArtistInfo:
    name: str
    mbid: str
    genres: list[str]
    members: list[str]


class RepairLimitReached(Exception):
    pass


def artist_info(artist: dict, cfg: Config) -> ArtistInfo:
    mbid = artist["foreignArtistId"]
    return ArtistInfo(
        name=artist.get("artistName") or "Unknown",
        mbid=mbid,
        genres=[g for g in artist.get("genres") or [] if g],
        members=musicbrainz.artist_members(mbid, cfg.cache_dir),
    )


def song_for(meta: dict, artist: ArtistInfo, cfg: Config) -> tuple[str, str]:
    """(song, "") for an upload the current rules accept, ("", reason) otherwise. The video is already in the
    library, so only the exclusions apply: not the duration limits or the music video marker (the upload's own
    channel name is often not the VEVO channel it was found on)."""
    decision = classify(
        {"title": meta.get("title") or "", "duration": meta.get("duration") or 1},
        artist.name,
        is_vevo=True,
        exclude_keywords=cfg.exclude_keywords,
        exclude_qualifiers=cfg.exclude_qualifiers,
        min_duration=0,
        max_duration=10**9,
        members=artist.members,
        require_marker=False,
    )
    return (decision.song, "") if decision.accepted else ("", decision.reason)


def repair_video(
    video: Path,
    video_id: str,
    artist: ArtistInfo,
    target_dir: Path,
    cfg: Config,
    state: State,
    stats: RepairStats,
    budget: list[int],
) -> None:
    entry = state.videos.setdefault(video_id, {"attempts": 0, "status": "downloaded"})
    entry.setdefault("artist", artist.mbid)
    stats.checked += 1
    meta = entry.get("meta")
    need_poster = entry.get("poster") != "youtube" or not library.poster_path(video).is_file()
    thumb = None
    can_look_up = entry.get("lookup_attempts", 0) < cfg.max_attempts
    if (not meta or need_poster) and can_look_up:
        if budget[0] <= 0:
            raise RepairLimitReached
        budget[0] -= 1
        stats.lookups += 1
        try:
            data, thumb = youtube.fetch_metadata(video_id, cfg, thumbnail=need_poster)
        except Exception as exc:  # noqa: BLE001 - removed/private/age-gated uploads; keep repairing the rest
            entry["lookup_attempts"] = entry.get("lookup_attempts", 0) + 1
            entry["lookup_error"] = str(exc)[:300]
            stats.failed += 1
            warning(f"{artist.name}: looking up {video_id} for '{video.name}' failed: {exc}")
        else:
            meta = {k: data.get(k) for k in META_FIELDS}
            entry["meta"] = meta
            entry.pop("lookup_error", None)
        if cfg.repair_delay:
            time.sleep(cfg.repair_delay)

    try:
        song, rejected = song_for(meta, artist, cfg) if meta and meta.get("title") else ("", "")
        stem = library.safe_name(song) if song else video.stem
        flag = f"would no longer be downloaded ({rejected})" if rejected else ""
        if (video.parent, video.stem) != (target_dir, stem):
            try:
                video = library.move_video(video, target_dir, stem)
                stats.renamed += 1
                info(f"{artist.name}: renamed to '{video.relative_to(cfg.library_path)}'")
            except FileExistsError as exc:
                flag = f"not renamed, {exc}"
        nfo = library.nfo_path(video)
        if meta:
            title, upload = song or video.stem, meta
        else:
            # The upload could not be looked up (removed, private, age-gated): keep what the NFO already says.
            known = library.nfo_fields(nfo)
            title, upload = known.get("title") or video.stem, known
        if library.write_nfo(
            nfo,
            title=title,
            artist=artist.name,
            video_id=video_id,
            info=upload,
            artist_mbid=artist.mbid,
            genres=artist.genres,
        ):
            stats.nfos += 1
        if thumb is not None:
            library.place_poster(thumb, video)
            thumb = None
            entry["poster"] = "youtube"
            stats.posters += 1
    finally:
        if thumb is not None:
            thumb.unlink(missing_ok=True)

    entry["path"] = str(video)
    entry["repaired"] = REPAIR_VERSION
    if flag:
        entry["flag"] = flag
        stats.flagged += 1
    else:
        entry.pop("flag", None)


def _belongs_to(artist: ArtistInfo, video: Path, video_id: str, state: State, shared: bool) -> bool:
    """Whether a video in the artist's folder is this artist's: Lidarr can have two artists with the same name,
    whose videos share a folder."""
    owner = state.videos.get(video_id, {}).get("artist") or library.nfo_fields(library.nfo_path(video)).get(
        "artist_mbid", ""
    )
    return owner == artist.mbid if owner else not shared


def repair_artist(
    artist: ArtistInfo, cfg: Config, state: State, stats: RepairStats, budget: list[int], *, shared: bool = False
) -> None:
    target_dir = library.artist_dir(cfg.library_path, artist.name)
    legacy_dir = cfg.library_path / library.legacy_safe_name(artist.name)
    folders = [target_dir] + ([legacy_dir] if legacy_dir != target_dir else [])
    ids_by_path = {v.get("path"): vid for vid, v in state.videos.items() if v.get("path")}
    for folder in folders:
        if not folder.is_dir():
            continue
        try:
            for video in sorted(p for p in folder.iterdir() if library.is_video(p)):
                video_id = library.nfo_video_id(library.nfo_path(video)) or ids_by_path.get(str(video), "")
                try:
                    if not video_id:
                        # Added by hand: keep its name, but follow the artist into the new folder.
                        if folder != target_dir and not shared:
                            try:
                                library.move_video(video, target_dir, video.stem)
                            except FileExistsError as exc:
                                warning(f"{artist.name}: not moving '{video.name}': {exc}")
                        continue
                    if not _belongs_to(artist, video, video_id, state, shared):
                        continue
                    repair_video(video, video_id, artist, target_dir, cfg, state, stats, budget)
                except OSError as exc:
                    # One unreadable/unmovable file must not stop the repair of everything after it.
                    stats.failed += 1
                    warning(f"{artist.name}: repairing '{video.name}' failed: {exc}")
                    if video_id in state.videos:
                        state.videos[video_id]["flag"] = f"repair failed: {str(exc)[:200]}"
        finally:
            state.save()
    try:
        if legacy_dir != target_dir and legacy_dir.is_dir() and not any(legacy_dir.iterdir()):
            legacy_dir.rmdir()
            info(f"{artist.name}: removed the old folder '{legacy_dir.name}'")
    except OSError as exc:
        warning(f"{artist.name}: could not remove the old folder '{legacy_dir.name}': {exc}")


def write_report(cfg: Config, state: State) -> Path | None:
    """List every video flagged by the repair (from state, so flags from earlier runs stay listed)."""
    rows = [
        f"| {v.get('path', vid)} | {(v.get('meta') or {}).get('title', '')} | {v['flag']} | https://youtu.be/{vid} |"
        for vid, v in sorted(state.videos.items(), key=lambda kv: str(kv[1].get("path")))
        if v.get("flag")
    ]
    report = cfg.state_dir / "repair-report.md"
    if not rows:
        report.unlink(missing_ok=True)
        return None
    lines = [
        "# Music video repair report",
        "",
        "Videos left as they are. Delete the ones you don't want; the sidecar will not download them again.",
        "",
        "| File | YouTube title | Why | URL |",
        "| --- | --- | --- | --- |",
        *rows,
    ]
    cfg.state_dir.mkdir(parents=True, exist_ok=True)
    report.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return report


def run(artists: list[dict], cfg: Config, state: State) -> RepairStats:
    stats = RepairStats()
    budget = [cfg.repair_max_per_run]
    folder_owners: dict[str, int] = {}
    for artist in artists:
        folder = library.safe_name(artist.get("artistName") or "Unknown").casefold()
        folder_owners[folder] = folder_owners.get(folder, 0) + 1
    for artist in artists:
        shared = folder_owners[library.safe_name(artist.get("artistName") or "Unknown").casefold()] > 1
        try:
            repair_artist(artist_info(artist, cfg), cfg, state, stats, budget, shared=shared)
        except RepairLimitReached:
            info(f"Repair lookup limit of {cfg.repair_max_per_run} reached; continuing next run")
            break
    report = write_report(cfg, state)
    info(
        f"Repair: {stats.checked} video(s) checked, {stats.renamed} renamed, {stats.nfos} NFO(s) and "
        f"{stats.posters} poster(s) written, {stats.lookups} lookup(s), {stats.failed} failed, {stats.flagged} flagged"
        + (f"; flagged videos listed in {report}" if report else "")
    )
    return stats
