#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

"""The Jellyfin music video library: <library>/<Artist>/<Song>.mkv with <Song>.nfo and <Song>-poster.jpg."""

from __future__ import annotations

import errno
import os
import re
import shutil
import xml.etree.ElementTree as ET
from collections.abc import Iterable
from pathlib import Path

from .classify import clean_song_title, file_safe, normalize_text, song_key, split_title

VIDEO_EXTENSIONS = {".mkv", ".mp4", ".webm", ".mov", ".m4v", ".avi"}
_LEGACY_UNSAFE = re.compile(r'[<>:"/\\|?*\x00-\x1f]')


def safe_name(name: str) -> str:
    """File or folder name: plain ASCII punctuation ("a‐ha" -> "a-ha"), unsafe characters replaced."""
    return file_safe(normalize_text(name)) or "Unknown"


def legacy_safe_name(name: str) -> str:
    """The folder name versions before 4.3 used: unsafe characters deleted, punctuation as given."""
    cleaned = re.sub(r"\s+", " ", _LEGACY_UNSAFE.sub("", str(name))).strip(" .")
    return cleaned or "Unknown"


def artist_dir(library: Path, artist: str) -> Path:
    return library / safe_name(artist)


def is_video(path: Path) -> bool:
    return path.suffix.lower() in VIDEO_EXTENSIONS and not path.name.startswith(".")


def nfo_path(video: Path) -> Path:
    return video.with_suffix(".nfo")


def poster_path(video: Path) -> Path:
    return video.with_name(f"{video.stem}-poster.jpg")


def nfo_video_id(path: Path) -> str:
    """The YouTube ID an NFO records (<uniqueid type="youtube">, or Jellyfin's own <youtubeid>)."""
    try:
        root = ET.parse(path).getroot()  # noqa: S314 - NFOs in our own library folder
    except (ET.ParseError, OSError):
        return ""
    for uid in root.iter("uniqueid"):
        if (uid.get("type") or "").lower() == "youtube" and uid.text:
            return uid.text.strip()
    return (root.findtext("youtubeid") or "").strip()


def nfo_fields(path: Path) -> dict:
    """What an existing NFO records: title, upload date (from premiered/year), channel (studio) and MusicBrainz
    artist ID; empty values for anything missing or an unreadable file."""
    try:
        root = ET.parse(path).getroot()  # noqa: S314 - NFOs in our own library folder
    except (ET.ParseError, OSError):
        return {}
    premiered = (root.findtext("premiered") or "").strip()
    year = (root.findtext("year") or "").strip()
    upload_date = premiered.replace("-", "") if re.fullmatch(r"\d{4}-\d{2}-\d{2}", premiered) else ""
    if not upload_date and re.fullmatch(r"\d{4}", year):
        upload_date = f"{year}0101"
    mbid = next(
        (
            u.text.strip()
            for u in root.iter("uniqueid")
            if (u.get("type") or "").lower() == "musicbrainzartist" and u.text
        ),
        "",
    )
    return {
        "title": (root.findtext("title") or "").strip(),
        "upload_date": upload_date,
        "channel": (root.findtext("studio") or "").strip(),
        "artist_mbid": mbid,
    }


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
            video_id = nfo_video_id(path)
            if video_id:
                ids.add(video_id)
    return keys, ids


def build_nfo(
    *,
    title: str,
    artist: str,
    video_id: str,
    info: dict,
    artist_mbid: str = "",
    genres: Iterable[str] = (),
) -> bytes:
    """Jellyfin/Kodi <musicvideo> NFO. <artist> must be the artist's exact name in the music library: Jellyfin
    links a music video to an artist by name. <lockdata> keeps Jellyfin from replacing the fields."""
    root = ET.Element("musicvideo")
    ET.SubElement(root, "title").text = title
    ET.SubElement(root, "artist").text = artist
    upload_date = str(info.get("upload_date") or "")
    if re.fullmatch(r"\d{8}", upload_date):
        ET.SubElement(root, "year").text = upload_date[:4]
        ET.SubElement(root, "premiered").text = f"{upload_date[:4]}-{upload_date[4:6]}-{upload_date[6:]}"
    if info.get("channel"):
        ET.SubElement(root, "studio").text = str(info["channel"])
    for genre in genres:
        if genre:
            ET.SubElement(root, "genre").text = str(genre)
    ET.SubElement(root, "lockdata").text = "true"
    uid = ET.SubElement(root, "uniqueid", {"type": "youtube", "default": "true"})
    uid.text = video_id
    if artist_mbid:
        ET.SubElement(root, "uniqueid", {"type": "musicbrainzartist"}).text = artist_mbid
    ET.indent(root)
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


def write_nfo(path: Path, **fields) -> bool:
    """Write the NFO unless it already has exactly this content; returns whether it was written."""
    data = build_nfo(**fields)
    try:
        if path.read_bytes() == data:
            return False
    except OSError:
        pass
    _write_atomic(path, data)
    return True


def _write_atomic(path: Path, data: bytes) -> None:
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_bytes(data)
    os.replace(tmp, path)


def place_poster(thumb: Path, video: Path) -> Path:
    """Move a downloaded thumbnail next to the video as <stem>-poster.jpg, replacing any poster there."""
    target = poster_path(video)
    partial = target.with_name(f".{target.name}.partial")
    try:
        shutil.move(str(thumb), str(partial))
        os.replace(partial, target)
    finally:
        partial.unlink(missing_ok=True)
    return target


def companions(video: Path) -> list[Path]:
    """The video's NFO, poster and other files sharing its name (subtitles), if present. Folders such as
    Jellyfin's "<stem>.trickplay" are not included."""
    found = []
    if not video.parent.is_dir():
        return found
    for path in video.parent.iterdir():
        if path == video or path.name.startswith(".") or not path.is_file():
            continue
        if path.name == f"{video.stem}-poster.jpg" or (path.name.startswith(f"{video.stem}.") and not is_video(path)):
            found.append(path)
    return found


def move_video(video: Path, directory: Path, stem: str) -> Path:
    """Rename a video and its companions to <directory>/<stem>.*; refuses to overwrite anything."""
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / f"{stem}{video.suffix.lower()}"
    if target == video:
        return video
    moves = [(video, target)]
    for path in companions(video):
        moves.append((path, directory / f"{stem}{path.name[len(video.stem) :]}"))
    # Same-name on a case-insensitive check is the same file being re-cased, not a clash.
    clashes = [dst for src, dst in moves if dst.exists() and not dst.samefile(src)]
    if clashes:
        raise FileExistsError(f"{clashes[0]} already exists")
    for src, dst in moves:
        _rename(src, dst)
    return target


def _rename(src: Path, dst: Path) -> None:
    """os.replace, falling back to a copy under a hidden name when mergerfs keeps the folders on different
    disks (EXDEV)."""
    try:
        os.replace(src, dst)
    except OSError as exc:
        if exc.errno != errno.EXDEV:
            raise
        partial = dst.with_name(f".{dst.name}.partial")
        try:
            shutil.copy2(src, partial)
            os.replace(partial, dst)
        finally:
            partial.unlink(missing_ok=True)
        src.unlink()


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
        shutil.move(str(thumb), str(poster_path(target)))
    partial = directory / f".{target.name}.partial"
    try:
        shutil.move(str(video), str(partial))
        os.replace(partial, target)
    finally:
        partial.unlink(missing_ok=True)
    return target
