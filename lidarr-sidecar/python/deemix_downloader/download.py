#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

"""Download and post-processing: deemix download, FLAC verification, tagging, import."""

from __future__ import annotations

import os
import shutil
import subprocess
import time
from pathlib import Path

from .config import cfg
from .logging import log
from .string_utils import clean_path_string

AUDIO_EXTENSIONS = (".flac", ".opus", ".m4a", ".mp3")


def setup_working_dirs() -> None:
    """Create/clean working directories."""
    cfg.staging_dir.mkdir(parents=True, exist_ok=True)
    cfg.complete_dir.mkdir(parents=True, exist_ok=True)
    cfg.cache_dir.mkdir(parents=True, exist_ok=True)
    cfg.downloaded_dir.mkdir(parents=True, exist_ok=True)
    cfg.failed_dir.mkdir(parents=True, exist_ok=True)
    cfg.notfound_dir.mkdir(parents=True, exist_ok=True)


def clean_staging() -> None:
    """Remove all files from staging directory."""
    if cfg.staging_dir.exists():
        shutil.rmtree(cfg.staging_dir)
    cfg.staging_dir.mkdir(parents=True, exist_ok=True)


def prune_cache() -> None:
    """Remove old cache entries based on configured max ages."""
    import time as _time

    now = _time.time()

    def _prune(prefix: str, max_days: int) -> None:
        if max_days <= 0:
            return
        max_age_secs = max_days * 86400
        for item in cfg.cache_dir.iterdir():
            if item.name.startswith(prefix) and item.is_file():
                if now - item.stat().st_mtime > max_age_secs:
                    item.unlink(missing_ok=True)

    _prune("mb-", cfg.cache_max_age_musicbrainz)
    _prune("deezer-", cfg.cache_max_age_deezer)
    # Lidarr cache is handled separately if needed


def verify_flac(file_path: Path) -> bool:
    """Verify a FLAC file for corruption using flac --test."""
    try:
        result = subprocess.run(
            ["flac", "--totally-silent", "-t", str(file_path)],
            capture_output=True,
            timeout=60,
        )
        return result.returncode == 0
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return False


def count_audio_files(directory: Path) -> int:
    """Count audio files in a directory."""
    count = 0
    for f in directory.rglob("*"):
        if f.is_file() and f.suffix.lower() in AUDIO_EXTENSIONS:
            count += 1
    return count


def consolidate_files(directory: Path) -> None:
    """Move all files from subdirectories to the root of directory."""
    for f in list(directory.rglob("*")):
        if f.is_file() and f.parent != directory:
            dest = directory / f.name
            if dest.exists():
                # Handle name collision
                stem = f.stem
                suffix = f.suffix
                dest = directory / f"{stem}_{int(time.time() * 1e9)}{suffix}"
                log.warning(f"Renamed duplicate: {f.name} -> {dest.name}")
            shutil.move(str(f), str(dest))

    # Remove empty subdirectories
    for d in sorted(directory.rglob("*"), reverse=True):
        if d.is_dir() and not any(d.iterdir()):
            d.rmdir()


def download_with_deemix(
    album_id: str,
    arl_token: str,
    quality: str = "flac",
    deemix_dir: Path = Path("/tmp/deemix"),
) -> bool:
    """
    Download an album using deemix CLI.
    Returns True on success.
    """
    url = f"https://www.deezer.com/album/{album_id}"

    try:
        result = subprocess.run(
            ["deemix", "--portable", "-p", str(cfg.staging_dir), "-b", quality, url],
            input=arl_token,
            text=True,
            capture_output=True,
            timeout=600,
            cwd=str(deemix_dir),
        )

        # Log output at debug level
        for line in result.stdout.splitlines():
            log.debug(f"deemix :: {line}")
        for line in result.stderr.splitlines():
            log.debug(f"deemix :: {line}")

        # Clean up temp deemix images
        tmp_imgs = Path("/tmp/deemix-imgs")
        if tmp_imgs.exists():
            shutil.rmtree(tmp_imgs, ignore_errors=True)

        return result.returncode == 0

    except subprocess.TimeoutExpired:
        log.warning(f"Deemix download timed out for album {album_id}")
        return False
    except FileNotFoundError:
        log.error("deemix command not found")
        return False


def tag_flac_musicbrainz(
    file_path: Path,
    album_title: str,
    release_id: str,
    release_group_id: str,
) -> None:
    """Tag a FLAC file with MusicBrainz IDs."""
    try:
        subprocess.run(
            [
                "metaflac",
                "--remove-tag=MUSICBRAINZ_ALBUMID",
                "--remove-tag=MUSICBRAINZ_RELEASEGROUPID",
                "--remove-tag=ALBUM",
                f"--set-tag=MUSICBRAINZ_ALBUMID={release_id}",
                f"--set-tag=MUSICBRAINZ_RELEASEGROUPID={release_group_id}",
                f"--set-tag=ALBUM={album_title}",
                str(file_path),
            ],
            capture_output=True,
            timeout=30,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        log.warning(f"Failed to tag FLAC {file_path.name}: {e}")


def tag_flac_artist(
    file_path: Path,
    artist_name: str,
    artist_foreign_id: str,
) -> None:
    """Tag a FLAC file with artist info."""
    try:
        subprocess.run(
            [
                "metaflac",
                "--remove-tag=MUSICBRAINZ_ARTISTID",
                "--remove-tag=ALBUMARTIST",
                "--remove-tag=ARTIST",
                f"--set-tag=MUSICBRAINZ_ARTISTID={artist_foreign_id}",
                f"--set-tag=ALBUMARTIST={artist_name}",
                f"--set-tag=ARTIST={artist_name}",
                str(file_path),
            ],
            capture_output=True,
            timeout=30,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        log.warning(f"Failed to tag FLAC artist {file_path.name}: {e}")


def tag_mp3_mutagen(
    file_path: Path,
    album_title: str = "",
    release_id: str = "",
    release_group_id: str = "",
    artist_name: str = "",
    artist_foreign_id: str = "",
) -> None:
    """Tag an MP3 file using mutagen directly (replaces MutagenTagger.py subprocess calls)."""
    try:
        from mutagen.id3 import ID3, ID3NoHeaderError, TALB, TPE1, TPE2, TXXX

        try:
            tags = ID3(str(file_path))
        except ID3NoHeaderError:
            tags = ID3()

        if album_title:
            tags.delall("TALB")
            tags.add(TALB(encoding=3, text=[album_title]))

        if artist_name:
            tags.delall("TPE1")
            tags.add(TPE1(encoding=3, text=[artist_name]))
            tags.delall("TPE2")
            tags.add(TPE2(encoding=3, text=[artist_name]))

        if release_id:
            tags.delall("TXXX:MUSICBRAINZ_ALBUMID")
            tags.add(TXXX(encoding=3, desc="MUSICBRAINZ_ALBUMID", text=[release_id]))

        if release_group_id:
            tags.delall("TXXX:MUSICBRAINZ_RELEASEGROUPID")
            tags.add(TXXX(encoding=3, desc="MUSICBRAINZ_RELEASEGROUPID", text=[release_group_id]))

        if artist_foreign_id:
            tags.delall("TXXX:MUSICBRAINZ_ARTISTID")
            tags.add(TXXX(encoding=3, desc="MUSICBRAINZ_ARTISTID", text=[artist_foreign_id]))

        tags.save(str(file_path))
    except Exception as e:
        log.warning(f"Failed to tag MP3 {file_path.name}: {e}")


def apply_replaygain(directory: Path) -> bool:
    """Apply ReplayGain tags using rsgain."""
    log.debug("Adding ReplayGain tags using rsgain")
    try:
        result = subprocess.run(
            ["rsgain", "easy", str(directory)],
            capture_output=True,
            text=True,
            timeout=300,
        )
        for line in result.stdout.splitlines():
            log.debug(f"rsgain :: {line}")
        return result.returncode == 0
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        log.warning(f"ReplayGain failed: {e}")
        return False


def apply_beets(
    directory: Path,
    release_foreign_id: str,
    beets_config_path: Path,
    beets_dir: Path,
) -> bool:
    """Apply Beets tagging with retry logic."""
    log.debug("Adding Beets tags")
    max_retries = 3
    delay = 5

    lib_path = beets_dir / "beets-library.blb"
    log_path = beets_dir / "beets.log"

    for attempt in range(max_retries + 1):
        # Reset beets state
        lib_path.unlink(missing_ok=True)
        log_path.unlink(missing_ok=True)
        lib_path.touch()

        env = os.environ.copy()
        env["XDG_CONFIG_HOME"] = str(beets_dir / ".config")
        env["HOME"] = str(beets_dir)

        verbosity = []
        log_level = os.environ.get("LOG_LEVEL", "INFO").upper()
        if log_level in ("DEBUG", "TRACE"):
            verbosity = ["-v"] if log_level == "DEBUG" else ["-vv"]

        cmd = [
            "beet",
            "-c", str(beets_config_path),
            "-l", str(lib_path),
            "-d", str(directory),
            *verbosity,
            "import", "-qCw",
            "-S", release_foreign_id,
            str(directory),
        ]

        try:
            result = subprocess.run(
                cmd,
                env=env,
                capture_output=True,
                text=True,
                timeout=300,
            )

            if result.returncode == 0:
                # Check for network errors in output
                if log_path.exists():
                    log_content = log_path.read_text(errors="ignore")
                    if any(
                        s in log_content
                        for s in ("MusicBrainz not reachable", "NetworkError", "UNEXPECTED_EOF_WHILE_READING")
                    ):
                        log.warning("MusicBrainz network failure detected in beets log")
                        if attempt < max_retries:
                            time.sleep(delay)
                            delay *= 2
                            continue
                        return False

                log.debug("Successfully added Beets tags")
                return True
            else:
                log.warning(f"Beets returned error code {result.returncode}")
                if attempt < max_retries:
                    log.warning(f"Retrying in {delay}s (attempt {attempt + 1}/{max_retries})")
                    time.sleep(delay)
                    delay *= 2
                    continue

        except subprocess.TimeoutExpired:
            log.warning("Beets timed out")
        except FileNotFoundError:
            log.error("beet command not found")
            return False

    return False


def move_to_import(
    artist_name: str,
    album_title: str,
    release_year: str,
    album_foreign_id: str = "",
) -> Path:
    """Move staged files to the shared import path. Returns the destination folder.

    Folder name format: 'Artist - Album (Year) [MusicBrainzReleaseGroupId]'
    The MBID suffix lets Lidarr positively identify the album even when
    artist/album names contain special characters it can't parse.
    """
    artist_clean = clean_path_string(artist_name[:100])
    album_clean = clean_path_string(album_title[:100])
    year_part = f" ({release_year})" if release_year else ""
    mbid_part = f" [{album_foreign_id}]" if album_foreign_id else ""

    folder_name = f"{artist_clean} - {album_clean}{year_part}{mbid_part}"
    dest = cfg.shared_lidarr_path / folder_name
    dest.mkdir(parents=True, exist_ok=True)

    for f in cfg.staging_dir.iterdir():
        if f.is_file() and f.suffix.lower() in AUDIO_EXTENSIONS:
            shutil.move(str(f), str(dest / f.name))

    return dest
