#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

"""
Simplified matching engine.

Strategy: Only accept releases that have a Deezer link in MusicBrainz.
Once a link is found, perform lightweight sanity checks to ensure it isn't
a broken or mistaken link. No fuzzy searching or deep track-by-track comparison.

Sanity checks:
1. The Deezer album must exist (not a 404/error)
2. Track count must be within a reasonable threshold
3. The album title must have some resemblance (not completely unrelated)
4. The album must not be filtered by lyric type settings
"""

from __future__ import annotations

from dataclasses import dataclass

from .config import cfg
from .deezer_api import get_deezer_album_info
from .logging import log
from .string_utils import levenshtein_distance, normalize_string


@dataclass
class MatchResult:
    """Result of the matching process for a single album."""

    deezer_album_id: str = ""
    deezer_title: str = ""
    deezer_year: str = ""
    deezer_track_count: int = 0
    lidarr_release_foreign_id: str = ""
    matched: bool = False
    reason: str = ""  # Why it was selected or rejected


@dataclass
class ReleaseCandidate:
    """A Lidarr release with its MusicBrainz-linked Deezer album ID."""

    title: str = ""
    disambiguation: str = ""
    foreign_id: str = ""
    track_count: int = 0
    deezer_album_id: str = ""
    release_status: str = ""
    year: str = ""
    format_priority: int = 999
    country_priority: int = 999
    contains_commentary: bool = False
    instrumental: bool = False
    explicit: bool = False


# ─── Sanity checks ────────────────────────────────────────────────────


def _title_is_reasonable(lidarr_title: str, deezer_title: str) -> bool:
    """
    Check that the Deezer album title is reasonably related to the Lidarr title.
    This is a loose check - we just want to catch completely wrong links
    (e.g., a link pointing to a totally different artist's album).

    Passes if:
    - Exact match (normalized)
    - One title contains the other
    - Levenshtein distance is < 50% of the longer title length
    """
    norm_lidarr = normalize_string(lidarr_title).lower()
    norm_deezer = normalize_string(deezer_title).lower()

    if not norm_lidarr or not norm_deezer:
        return True  # Can't compare, give benefit of doubt

    if norm_lidarr == norm_deezer:
        return True

    if norm_lidarr in norm_deezer or norm_deezer in norm_lidarr:
        return True

    max_len = max(len(norm_lidarr), len(norm_deezer))
    distance = levenshtein_distance(norm_lidarr, norm_deezer)
    return distance <= max_len // 2


def _track_count_is_reasonable(lidarr_count: int, deezer_count: int) -> bool:
    """
    Check that track counts are within reason.
    Allow up to 50% difference or 3 tracks absolute (whichever is more generous).
    This catches cases where a Deezer link points to a single instead of an album.
    """
    if lidarr_count <= 0 or deezer_count <= 0:
        return True

    diff = abs(lidarr_count - deezer_count)
    max_count = max(lidarr_count, deezer_count)
    return diff <= 3 or diff <= max_count // 2


def _should_skip_by_lyric_type(explicit: bool) -> bool:
    """Check if album should be skipped based on lyric type filter."""
    if cfg.lyric_type == "require-clean" and explicit:
        return True
    if cfg.lyric_type == "require-explicit" and not explicit:
        return True
    return False


# ─── Release ranking ───────────────────────────────────────────────────


def _rank_release(candidate: ReleaseCandidate) -> tuple:
    """
    Sort key for ranking releases. Lower is better.
    1. Not commentary
    2. Not instrumental
    3. Country priority
    4. Format priority
    5. Higher track count
    """
    return (
        int(candidate.contains_commentary),
        int(candidate.instrumental),
        candidate.country_priority,
        candidate.format_priority,
        -candidate.track_count,
    )


# ─── Main matching function ─────────────────────────────────────────────


def find_best_match(
    releases: list[ReleaseCandidate],
    lidarr_album_title: str,
    failed_albums: set[str],
) -> MatchResult:
    """
    Find the best Deezer match from a list of Lidarr releases.

    Only considers releases that have a Deezer link in MusicBrainz.
    Applies sanity checks to validate the link isn't broken/wrong.
    Ranks valid candidates by release quality criteria.
    """
    # Filter to only releases with Deezer links
    linked = [r for r in releases if r.deezer_album_id]

    if not linked:
        return MatchResult(reason="No releases have a Deezer link in MusicBrainz")

    # Filter out non-official releases
    official = [r for r in linked if r.release_status == "Official"]
    if not official:
        official = linked

    # Skip commentary if configured
    if cfg.deprioritize_commentary:
        non_commentary = [r for r in official if not r.contains_commentary]
        if non_commentary:
            official = non_commentary

    # Skip instrumental if configured
    if cfg.ignore_instrumental:
        non_instrumental = [r for r in official if not r.instrumental]
        if non_instrumental:
            official = non_instrumental

    # Sort by ranking criteria
    official.sort(key=_rank_release)

    # Try each candidate in rank order
    for candidate in official:
        deezer_id = candidate.deezer_album_id

        # Skip previously failed
        if deezer_id in failed_albums:
            log.debug(f"Skipping Deezer album {deezer_id} (previously failed)")
            continue

        # Fetch Deezer album info (validates the link isn't broken)
        album_data = get_deezer_album_info(deezer_id)
        if album_data is None:
            log.warning(f"Deezer album {deezer_id} could not be fetched (broken link?)")
            continue

        # Use the actual ID from the response (handles Deezer redirects/remaps)
        actual_deezer_id = str(album_data.get("id", deezer_id))
        if actual_deezer_id != deezer_id:
            log.info(f"Deezer album {deezer_id} redirected to {actual_deezer_id}")
            if actual_deezer_id in failed_albums:
                log.debug(f"Skipping remapped Deezer album {actual_deezer_id} (previously failed)")
                continue

        deezer_title = album_data.get("title", "")
        deezer_track_count = album_data.get("nb_tracks", 0)
        deezer_explicit = album_data.get("explicit_lyrics", False)
        deezer_release_date = album_data.get("release_date", "")
        deezer_year = deezer_release_date[:4] if deezer_release_date else ""

        # Sanity check: lyric type
        if _should_skip_by_lyric_type(deezer_explicit):
            log.debug(f"Skipping Deezer album {deezer_id} ({deezer_title}) - lyric type filter")
            continue

        # Sanity check: title reasonableness
        search_title = candidate.title or lidarr_album_title
        if not _title_is_reasonable(search_title, deezer_title):
            log.warning(
                f"Deezer album {deezer_id} title \"{deezer_title}\" doesn't match "
                f"expected \"{search_title}\" - possible bad MusicBrainz link"
            )
            continue

        # Sanity check: track count
        if not _track_count_is_reasonable(candidate.track_count, deezer_track_count):
            log.warning(
                f"Deezer album {deezer_id} has {deezer_track_count} tracks but "
                f"expected ~{candidate.track_count} - possible bad MusicBrainz link"
            )
            continue

        # All checks pass
        log.info(
            f"Matched: \"{deezer_title}\" ({actual_deezer_id}) "
            f"[tracks: {deezer_track_count}, year: {deezer_year}]"
        )
        return MatchResult(
            deezer_album_id=actual_deezer_id,
            deezer_title=deezer_title,
            deezer_year=deezer_year,
            deezer_track_count=deezer_track_count,
            lidarr_release_foreign_id=candidate.foreign_id,
            matched=True,
            reason="Matched via MusicBrainz Deezer link",
        )

    return MatchResult(reason="All Deezer links failed sanity checks")
