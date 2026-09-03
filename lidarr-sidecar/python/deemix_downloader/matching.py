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
    lidarr_release_id: str = ""
    lidarr_release_foreign_id: str = ""
    matched: bool = False
    was_redirected: bool = False
    reason: str = ""  # Why it was selected or rejected


@dataclass
class ReleaseCandidate:
    """A Lidarr release with its MusicBrainz-linked Deezer album ID."""

    title: str = ""
    disambiguation: str = ""
    release_id: str = ""
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
    alternate_titles: list[str] | None = None
    musicbrainz_barcode: str = ""
    # Count of tracks on the MB release marked as video recordings. Lidarr's
    # trackCount excludes these, but Deezer sometimes includes their audio as
    # part of the album - inflating deezer_track_count above trackCount.
    video_track_count: int = 0


# ─── Sanity checks ────────────────────────────────────────────────────


def _title_is_reasonable(
    lidarr_title: str,
    deezer_title: str,
    alternate_titles: list[str] | None = None,
) -> bool:
    """
    Check that the Deezer album title is reasonably related to the Lidarr title.
    This is a loose check - we just want to catch completely wrong links
    (e.g., a link pointing to a totally different artist's album).

    Passes if:
    - Exact match (normalized)
    - One title contains the other
    - Levenshtein distance is < 50% of the longer title length

    Alternate titles are treated as additional candidate titles for comparison.
    """
    titles_to_compare = [lidarr_title]
    if alternate_titles:
        titles_to_compare.extend(
            title for title in alternate_titles if title and title not in titles_to_compare
        )

    if not deezer_title:
        return True

    norm_deezer = normalize_string(deezer_title).lower()
    if not norm_deezer:
        return True

    for title in titles_to_compare:
        norm_lidarr = normalize_string(title).lower()
        if not norm_lidarr:
            continue

        if norm_lidarr == norm_deezer:
            return True

        if norm_lidarr in norm_deezer or norm_deezer in norm_lidarr:
            return True

        max_len = max(len(norm_lidarr), len(norm_deezer))
        distance = levenshtein_distance(norm_lidarr, norm_deezer)
        if distance <= max_len // 2:
            return True

    return False


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


def _has_video_track_inflation(
    lidarr_count: int, deezer_count: int, video_track_count: int
) -> bool:
    """
    Detect a Deezer album that likely includes audio for tracks MusicBrainz
    marks as video-only (e.g. live-video bonus tracks): Lidarr's trackCount
    already excludes those, so a Deezer album significantly LARGER than
    trackCount on a release that has video tracks isn't a looser-but-valid
    match - it's audio for tracks Lidarr will never have a slot for, so every
    file would come back "unmatched" from a real import.
    """
    if video_track_count <= 0 or deezer_count <= lidarr_count:
        return False
    return deezer_count >= lidarr_count + video_track_count - 2


def _should_skip_by_lyric_type(explicit: bool) -> bool:
    """Check if album should be skipped based on lyric type filter."""
    if cfg.lyric_type == "require-clean" and explicit:
        return True
    if cfg.lyric_type == "require-explicit" and not explicit:
        return True
    return False


def _normalize_upc(value: str) -> str:
    """Normalize UPC for comparison by keeping digits and trimming leading zeros."""
    digits = "".join(ch for ch in str(value).strip() if ch.isdigit())
    if not digits:
        return ""
    return digits.lstrip("0") or "0"


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

    reject_counts: dict[str, int] = {
        "previously_failed": 0,
        "deezer_fetch_failed": 0,
        "redirect_rejected": 0,
        "upc_mismatch": 0,
        "lyric_type": 0,
        "title_mismatch": 0,
        "track_count_mismatch": 0,
        "video_track_inflation": 0,
    }

    # Try each candidate in rank order
    for candidate in official:
        deezer_id = candidate.deezer_album_id

        # Skip previously failed
        if deezer_id in failed_albums:
            log.debug(f"Skipping Deezer album {deezer_id} (previously failed)")
            reject_counts["previously_failed"] += 1
            continue

        # Fetch Deezer album info (validates the link isn't broken)
        album_data = get_deezer_album_info(deezer_id)
        if album_data is None:
            log.warning(f"Deezer album {deezer_id} could not be fetched (broken link?)")
            reject_counts["deezer_fetch_failed"] += 1
            continue

        # Use the actual ID from the response (handles Deezer redirects/remaps)
        actual_deezer_id = str(album_data.get("id", deezer_id))
        is_redirected = actual_deezer_id != deezer_id
        if actual_deezer_id != deezer_id:
            log.info(f"Deezer album {deezer_id} redirected to {actual_deezer_id}")
            if actual_deezer_id in failed_albums:
                log.debug(f"Skipping remapped Deezer album {actual_deezer_id} (previously failed)")
                reject_counts["previously_failed"] += 1
                continue
            if cfg.require_non_redirect_deezer:
                log.info(
                    f"Skipping Deezer album {deezer_id}: redirected to {actual_deezer_id} "
                    "and AUDIO_REQUIRE_NON_REDIRECT_DEEZER is enabled"
                )
                reject_counts["redirect_rejected"] += 1
                continue

        deezer_title = album_data.get("title", "")
        deezer_track_count = album_data.get("nb_tracks", 0)
        deezer_explicit = album_data.get("explicit_lyrics", False)
        deezer_release_date = album_data.get("release_date", "")
        deezer_year = deezer_release_date[:4] if deezer_release_date else ""

        # Hard gate: UPC must match (after normalizing leading-zero padded values)
        if cfg.require_upc_match:
            mb_upc = _normalize_upc(candidate.musicbrainz_barcode)
            deezer_upc = _normalize_upc(str(album_data.get("upc", "") or ""))
            if not mb_upc or not deezer_upc or mb_upc != deezer_upc:
                log.info(
                    f"Skipping Deezer album {deezer_id}: UPC mismatch "
                    f"(MusicBrainz={candidate.musicbrainz_barcode or 'missing'}, "
                    f"Deezer={album_data.get('upc', '') or 'missing'})"
                )
                reject_counts["upc_mismatch"] += 1
                continue

        # Sanity check: lyric type
        if _should_skip_by_lyric_type(deezer_explicit):
            log.debug(f"Skipping Deezer album {deezer_id} ({deezer_title}) - lyric type filter")
            reject_counts["lyric_type"] += 1
            continue

        # Sanity check: title reasonableness
        search_title = candidate.title or lidarr_album_title
        if not _title_is_reasonable(
            search_title,
            deezer_title,
            candidate.alternate_titles,
        ):
            log.warning(
                f"Deezer album {deezer_id} title \"{deezer_title}\" doesn't match "
                f"expected \"{search_title}\" - possible bad MusicBrainz link"
            )
            reject_counts["title_mismatch"] += 1
            continue

        # Sanity check: track count
        if _has_video_track_inflation(
            candidate.track_count, deezer_track_count, candidate.video_track_count
        ):
            log.warning(
                f"Deezer album {deezer_id} has {deezer_track_count} tracks but MusicBrainz release "
                f"only has {candidate.track_count} audio tracks ({candidate.video_track_count} video "
                "tracks likely included in the Deezer album) - rejecting"
            )
            reject_counts["video_track_inflation"] += 1
            continue

        if not _track_count_is_reasonable(candidate.track_count, deezer_track_count):
            log.warning(
                f"Deezer album {deezer_id} has {deezer_track_count} tracks but "
                f"expected ~{candidate.track_count} - possible bad MusicBrainz link"
            )
            reject_counts["track_count_mismatch"] += 1
            continue

        # All checks pass
        log.info(
            f"Matched: \"{deezer_title}\" ({actual_deezer_id}) "
            f"[tracks: {deezer_track_count}, year: {deezer_year}]"
        )
        match_result = MatchResult(
            deezer_album_id=actual_deezer_id,
            deezer_title=deezer_title,
            deezer_year=deezer_year,
            deezer_track_count=deezer_track_count,
            lidarr_release_id=candidate.release_id,
            lidarr_release_foreign_id=candidate.foreign_id,
            matched=True,
            was_redirected=is_redirected,
            reason=(
                "Matched via MusicBrainz Deezer link (redirected Deezer ID)"
                if is_redirected
                else "Matched via MusicBrainz Deezer link"
            ),
        )

        return match_result

    summary_parts = [
        f"redirect gate rejected={reject_counts['redirect_rejected']}",
        f"upc mismatch={reject_counts['upc_mismatch']}",
        f"deezer fetch failed={reject_counts['deezer_fetch_failed']}",
        f"lyric type={reject_counts['lyric_type']}",
        f"title mismatch={reject_counts['title_mismatch']}",
        f"track mismatch={reject_counts['track_count_mismatch']}",
        f"video track inflation={reject_counts['video_track_inflation']}",
        f"previously failed={reject_counts['previously_failed']}",
    ]
    return MatchResult(
        reason="All Deezer links failed sanity checks: " + ", ".join(summary_parts)
    )
