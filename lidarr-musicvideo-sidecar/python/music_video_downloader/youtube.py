#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

"""yt-dlp wrappers: list a channel's uploads and download one video as MKV plus a JPG thumbnail."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from .config import Config

_ENTRY_FIELDS = ("id", "title", "duration", "view_count", "live_status")


@dataclass
class Channel:
    url: str
    name: str
    entries: list[dict]
    channel_id: str = ""

    @property
    def is_vevo(self) -> bool:
        return self.name.strip().lower().endswith("vevo")


def _base_opts(cfg: Config) -> dict:
    opts = {
        "quiet": True,
        "no_warnings": True,
        "noprogress": True,
        # The container's filesystem is read-only apart from its mounts and /tmp.
        "cachedir": False,
        "socket_timeout": 30,
        "retries": 3,
        "fragment_retries": 3,
    }
    if cfg.cookies_file:
        opts["cookiefile"] = cfg.cookies_file
    return opts


def list_channel(url: str, cfg: Config) -> Channel:
    import yt_dlp

    opts = {**_base_opts(cfg), "extract_flat": "in_playlist", "skip_download": True}
    with yt_dlp.YoutubeDL(opts) as ydl:
        info = ydl.extract_info(f"{url.rstrip('/')}/videos", download=False) or {}
    entries = [{k: e.get(k) for k in _ENTRY_FIELDS} for e in info.get("entries") or [] if e and e.get("id")]
    return Channel(
        url=url,
        name=info.get("channel") or info.get("uploader") or "",
        entries=entries,
        channel_id=info.get("channel_id") or "",
    )


_VIDEO_SUFFIXES = (".mkv", ".mp4", ".webm", ".mov", ".m4v")


def download(video_id: str, cfg: Config) -> tuple[Path, Path | None, dict]:
    """Download into cfg.work_dir as <id>.mkv (+ <id>.jpg). Returns (video, thumbnail, info)."""
    import yt_dlp

    work = cfg.work_dir
    work.mkdir(parents=True, exist_ok=True)
    opts = {
        **_base_opts(cfg),
        "format": cfg.format,
        "merge_output_format": "mkv",
        "paths": {"home": str(work), "temp": str(work)},
        "outtmpl": {"default": "%(id)s.%(ext)s"},
        "writethumbnail": True,
        "postprocessors": [
            {"key": "FFmpegThumbnailsConvertor", "format": "jpg", "when": "before_dl"},
            # A single-file format (the "/b" fallback) is an MP4 or WebM; remux it so the library is all MKV.
            {"key": "FFmpegVideoRemuxer", "preferedformat": "mkv"},
        ],
    }
    with yt_dlp.YoutubeDL(opts) as ydl:
        info = ydl.extract_info(f"https://www.youtube.com/watch?v={video_id}", download=True) or {}
    video = next((work / f"{video_id}{s}" for s in _VIDEO_SUFFIXES if (work / f"{video_id}{s}").is_file()), None)
    if video is None:
        raise FileNotFoundError(f"yt-dlp finished without a video file for {video_id}")
    thumb = work / f"{video_id}.jpg"
    return video, thumb if thumb.is_file() else None, info


def fetch_metadata(video_id: str, cfg: Config, *, thumbnail: bool) -> tuple[dict, Path | None]:
    """The upload's metadata (title, upload date, channel, duration) without downloading the video, and
    optionally its thumbnail as <work>/<id>.jpg."""
    import yt_dlp

    work = cfg.work_dir
    work.mkdir(parents=True, exist_ok=True)
    opts = {
        **_base_opts(cfg),
        "skip_download": True,
        "paths": {"home": str(work), "temp": str(work)},
        "outtmpl": {"default": "%(id)s.%(ext)s"},
        "writethumbnail": thumbnail,
        "postprocessors": [{"key": "FFmpegThumbnailsConvertor", "format": "jpg", "when": "before_dl"}]
        if thumbnail
        else [],
    }
    with yt_dlp.YoutubeDL(opts) as ydl:
        info = ydl.extract_info(f"https://www.youtube.com/watch?v={video_id}", download=thumbnail) or {}
    thumb = work / f"{video_id}.jpg"
    return info, thumb if thumbnail and thumb.is_file() else None
