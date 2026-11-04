#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

"""The Jellyfin music video library: <library>/<Artist>/<Song>.mkv with <Song>.nfo and <Song>-poster.jpg."""

from __future__ import annotations

import os
import re
import shutil
import xml.etree.ElementTree as ET
from pathlib import Path

from .classify import clean_song_title, song_key, split_title

VIDEO_EXTENSIONS = {".mkv", ".mp4", ".webm", ".mov", ".m4v", ".avi"}
_UNSAFE = re.compile(r'[<>:"/\\|?*\x00-\x1f]')


def safe_name(name: str) -> str:
    cleaned = re.sub(r"\s+", " ", _UNSAFE.sub("", str(name))).strip(" .")
    return cleaned or "Unknown"


def artist_dir(library: Path, artist: str) -> Path:
    return library / safe_name(artist)


def existing_videos(directory: Path, artist: str) -> tuple[set[str], set[str]]:
    """Song keys of the videos already in an artist folder, and the YouTube IDs their NFOs record.

    Videos added by hand count too, so nothing is downloaded twice.
    """
    keys: set[str] = set()
    ids: set[str] = set()
    if not directory.is_dir():
        return keys, ids
    for path in directory.iterdir():
        if path.suffix.lower() in VIDEO_EXTENSIONS:
            song, _, _ = split_title(path.stem, artist)
            key = song_key(clean_song_title(song))
            if key:
                keys.add(key)
        elif path.suffix.lower() == ".nfo":
            try:
                root = ET.parse(path).getroot()  # noqa: S314 - NFOs in our own library folder
            except (ET.ParseError, OSError):
                continue
            for uid in root.iter("uniqueid"):
                if (uid.get("type") or "").lower() == "youtube" and uid.text:
                    ids.add(uid.text.strip())
    return keys, ids


def write_nfo(path: Path, *, title: str, artist: str, video_id: str, info: dict) -> None:
    root = ET.Element("musicvideo")
    ET.SubElement(root, "title").text = title
    ET.SubElement(root, "artist").text = artist
    upload_date = str(info.get("upload_date") or "")
    if re.fullmatch(r"\d{8}", upload_date):
        ET.SubElement(root, "year").text = upload_date[:4]
        ET.SubElement(root, "premiered").text = f"{upload_date[:4]}-{upload_date[4:6]}-{upload_date[6:]}"
    if info.get("channel"):
        ET.SubElement(root, "studio").text = str(info["channel"])
    uid = ET.SubElement(root, "uniqueid", {"type": "youtube", "default": "true"})
    uid.text = video_id
    ET.indent(root)
    path.write_bytes(ET.tostring(root, encoding="utf-8", xml_declaration=True))


def install(video: Path, thumb: Path | None, directory: Path, song: str) -> Path:
    """Move a finished download into the artist folder; returns the library path of the video.

    The work folder is usually on another filesystem, so the move is a copy. It goes to a hidden ".partial"
    name first and is renamed once complete: library watchers (Jellyfin, Tdarr) never see a half-written video.
    """
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / f"{safe_name(song)}{video.suffix.lower()}"
    if target.exists():
        raise FileExistsError(f"{target} already exists")
    if thumb is not None:
        shutil.move(str(thumb), str(target.with_name(f"{target.stem}-poster.jpg")))
    partial = directory / f".{target.name}.partial"
    try:
        shutil.move(str(video), str(partial))
        os.replace(partial, target)
    finally:
        partial.unlink(missing_ok=True)
    return target
