#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

"""MusicVideoDownloader: official music videos for Lidarr artists, from their YouTube channels.

Each run takes the monitored Lidarr artists (optionally only those with VIDEO_ARTIST_TAG) that were not
checked in the last VIDEO_ARTIST_RECHECK_DAYS, looks up their official YouTube channels in MusicBrainz,
lists the uploads with yt-dlp, keeps the music videos (see classify.py), and downloads the ones not yet
in the library - at most VIDEO_MAX_DOWNLOADS_PER_RUN per run - into <library>/<Artist>/<Song>.mkv with
an NFO and a poster for Jellyfin.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

from shared.python.arrapi import arr_api_request
from shared.python.logging_utils import debug, error, info, warning
from shared.python.state import get_state

from . import artwork, library, musicbrainz, repair, youtube
from .classify import Decision, classify, select_videos
from .config import Config
from .state import State


@dataclass
class RunStats:
    artists_checked: int = 0
    artists_without_channel: int = 0
    selected: int = 0
    downloaded: int = 0
    failed: int = 0
    planned: list[str] = field(default_factory=list)


class DownloadLimitReached(Exception):
    pass


def lidarr_artists(cfg: Config) -> list[dict]:
    """Monitored Lidarr artists, limited to those tagged VIDEO_ARTIST_TAG when it is set."""
    arr_api_request("GET", "artist")
    artists = get_state("arrApiResponse") or []
    artists = [a for a in artists if a.get("monitored") and a.get("foreignArtistId")]
    if cfg.artist_tag:
        arr_api_request("GET", "tag")
        tags = {t.get("label", "").lower(): t.get("id") for t in get_state("arrApiResponse") or []}
        tag_id = tags.get(cfg.artist_tag.lower())
        if tag_id is None:
            warning(f"Lidarr tag '{cfg.artist_tag}' does not exist; no artists selected")
            return []
        artists = [a for a in artists if tag_id in (a.get("tags") or [])]
    # Lidarr's placeholder artist for compilations has no channel of its own.
    return [a for a in artists if a.get("foreignArtistId") != "89ad4ac3-39f7-470e-963a-56509c546377"]


def music_videos_for(
    artist_name: str, channels: list[youtube.Channel], cfg: Config, members: list[str] | None = None
) -> list[tuple[dict, Decision]]:
    candidates = []
    for channel in channels:
        for entry in channel.entries:
            decision = classify(
                entry,
                artist_name,
                is_vevo=channel.is_vevo,
                exclude_keywords=cfg.exclude_keywords,
                exclude_qualifiers=cfg.exclude_qualifiers,
                min_duration=cfg.min_duration,
                max_duration=cfg.max_duration,
                members=members or (),
            )
            debug(f"{artist_name} | {channel.name} | {entry.get('title')} -> {decision.reason}")
            candidates.append((entry, decision))
    return select_videos(candidates)


def process_artist(artist: dict, cfg: Config, state: State, stats: RunStats, budget: list[int]) -> None:
    name = artist.get("artistName") or "Unknown"
    mbid = artist["foreignArtistId"]
    urls = musicbrainz.artist_channels(mbid, cfg.cache_dir)
    if not urls:
        stats.artists_without_channel += 1
        if not cfg.dry_run:
            state.mark_artist(mbid, name, channels=0)
        debug(f"{name}: no YouTube channel in MusicBrainz")
        return

    channels: list[youtube.Channel] = []
    for url in urls:
        try:
            channel = youtube.list_channel(url, cfg)
        except Exception as exc:  # noqa: BLE001 - yt-dlp raises many types; one bad channel must not stop the run
            warning(f"{name}: listing {url} failed: {exc}")
            continue
        # MusicBrainz often links one channel twice (/channel/UC... and its legacy /user/ URL).
        if channel.channel_id and any(c.channel_id == channel.channel_id for c in channels):
            continue
        channels.append(channel)
    members = musicbrainz.artist_members(mbid, cfg.cache_dir)
    picks = music_videos_for(name, channels, cfg, members)
    stats.artists_checked += 1
    stats.selected += len(picks)

    directory = library.artist_dir(cfg.library_path, name)
    have_keys, have_ids = library.existing_videos(directory, name)
    # Until the repair has moved them, an artist's videos may still be in the folder named the old way.
    legacy = cfg.library_path / library.legacy_safe_name(name)
    if legacy != directory:
        legacy_keys, legacy_ids = library.existing_videos(legacy, name)
        have_keys |= legacy_keys
        have_ids |= legacy_ids
    pending = [
        (entry, decision)
        for entry, decision in picks
        if entry["id"] not in have_ids
        and decision.key not in have_keys
        and not state.video_done(entry["id"], cfg.max_attempts)
    ]
    info(f"{name}: {len(picks)} music video(s) on {len(channels)} channel(s), {len(pending)} to download")

    for entry, decision in pending:
        if cfg.dry_run:
            stats.planned.append(
                f"| {name} | {decision.song} | {entry.get('title')} | https://youtu.be/{entry['id']} |"
            )
            continue
        if budget[0] <= 0:
            raise DownloadLimitReached
        budget[0] -= 1
        try:
            video, thumb, meta = youtube.download(entry["id"], cfg)
            target = library.install(video, thumb, directory, decision.song)
            library.write_nfo(
                library.nfo_path(target),
                title=decision.song,
                artist=name,
                video_id=entry["id"],
                info=meta,
                artist_mbid=mbid,
                genres=[g for g in artist.get("genres") or [] if g],
            )
        except Exception as exc:  # noqa: BLE001 - record any download/move failure and carry on
            stats.failed += 1
            state.record_video(entry["id"], "failed", artist=mbid, song=decision.song, error=str(exc)[:300])
            warning(f"{name}: '{decision.song}' ({entry['id']}) failed: {exc}")
        else:
            stats.downloaded += 1
            state.record_video(
                entry["id"],
                "downloaded",
                artist=mbid,
                song=decision.song,
                path=str(target),
                meta={k: meta.get(k) for k in repair.META_FIELDS},
                poster="youtube" if thumb is not None else None,
                repaired=repair.REPAIR_VERSION,
            )
            info(f"{name}: downloaded '{decision.song}' -> {target}")
        state.save()
        if cfg.download_delay:
            time.sleep(cfg.download_delay)

    if not cfg.dry_run:
        state.mark_artist(mbid, name, channels=len(channels), music_videos=len(picks))


def run_once(cfg: Config, state: State) -> RunStats:
    stats = RunStats()
    artists = lidarr_artists(cfg)
    due = [a for a in artists if cfg.dry_run or state.artist_due(a["foreignArtistId"], cfg.artist_recheck_days)]
    due.sort(key=lambda a: state.artists.get(a["foreignArtistId"], {}).get("checked", 0))
    info(f"{len(artists)} artist(s) selected, {len(due)} due for a check")
    budget = [cfg.max_downloads_per_run]
    for artist in due:
        try:
            process_artist(artist, cfg, state, stats, budget)
        except DownloadLimitReached:
            info(f"Download limit of {cfg.max_downloads_per_run} reached; continuing next run")
            break
        if not cfg.dry_run:
            state.save()
    if cfg.dry_run:
        write_dry_run_report(cfg, stats)
    else:
        if cfg.repair:
            repair.run(artists, cfg, state)
        if cfg.artist_artwork:
            artwork.run(artists, cfg)
    return stats


def write_dry_run_report(cfg: Config, stats: RunStats) -> Path:
    cfg.state_dir.mkdir(parents=True, exist_ok=True)
    report = cfg.state_dir / f"dry-run-{datetime.now():%Y%m%d-%H%M%S}.md"
    lines = ["| Artist | Song | YouTube title | URL |", "| --- | --- | --- | --- |", *stats.planned]
    report.write_text("\n".join(lines) + "\n", encoding="utf-8")
    info(f"Dry run: {len(stats.planned)} video(s) would be downloaded; list in {report}")
    return report


def main() -> None:
    cfg = Config()
    info(
        f"Starting MusicVideoDownloader (library {cfg.library_path}, interval {cfg.interval}, "
        f"tag '{cfg.artist_tag or '(all monitored)'}', limit {cfg.max_downloads_per_run}/run"
        f"{', DRY RUN' if cfg.dry_run else ''})"
    )
    interval = cfg.interval_seconds
    state = State(cfg.state_file)
    while True:
        try:
            stats = run_once(cfg, state)
            info(
                f"Run complete: {stats.artists_checked} artist(s) checked, {stats.artists_without_channel} without a "
                f"channel, {stats.selected} music video(s) found, {stats.downloaded} downloaded, {stats.failed} failed"
            )
        except Exception as exc:  # noqa: BLE001 - keep the service alive; the next run retries
            error(f"Run failed: {exc}")
        if not interval:
            info("VIDEO_INTERVAL is 'none', exiting after a single run")
            return
        info(f"Sleeping for {cfg.interval}...")
        time.sleep(interval)
