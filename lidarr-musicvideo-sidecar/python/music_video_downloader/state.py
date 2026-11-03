#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

"""Persistent state: when each artist was last checked, and the outcome for each YouTube video."""

from __future__ import annotations

import json
import os
import time
from pathlib import Path


class State:
    def __init__(self, path: Path):
        self.path = path
        self.artists: dict[str, dict] = {}
        self.videos: dict[str, dict] = {}
        if path.is_file():
            data = json.loads(path.read_text(encoding="utf-8"))
            self.artists = data.get("artists", {})
            self.videos = data.get("videos", {})

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps({"artists": self.artists, "videos": self.videos}, indent=1), encoding="utf-8")
        os.replace(tmp, self.path)

    def artist_due(self, mbid: str, recheck_days: int, now: float | None = None) -> bool:
        checked = self.artists.get(mbid, {}).get("checked", 0)
        return (now or time.time()) - checked >= recheck_days * 86400

    def mark_artist(self, mbid: str, name: str, **extra) -> None:
        self.artists[mbid] = {"name": name, "checked": time.time(), **extra}

    def video_done(self, video_id: str, max_attempts: int) -> bool:
        entry = self.videos.get(video_id)
        if not entry:
            return False
        return entry.get("status") == "downloaded" or entry.get("attempts", 0) >= max_attempts

    def record_video(self, video_id: str, status: str, **extra) -> None:
        entry = self.videos.setdefault(video_id, {"attempts": 0})
        if status == "failed":
            entry["attempts"] = entry.get("attempts", 0) + 1
        entry.update({"status": status, "updated": time.time(), **extra})
