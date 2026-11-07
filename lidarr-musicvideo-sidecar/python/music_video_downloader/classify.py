#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

"""Decide which uploads on an artist's official YouTube channels are music videos.

Pure functions only: the inputs are yt-dlp flat playlist entries (title, duration, view count) and the
artist's name. An upload is a music video when its title is marked as one ("Official Music Video", "Official Video",
"(Music Video)"), credits a featured artist ("Song (feat. X)"), or - on a VEVO channel, which only carries
label uploads - is a plain "<Artist> - <Song>" upload. It must carry no marker of another kind of upload:
title keywords (lyric video, visualizer, behind the scenes, ...) or qualifier words in brackets and
trailing " - ..." / " | ..." parts (live, audio, cover, episode, ...).
"""

from __future__ import annotations

import re
import unicodedata
from collections.abc import Iterable
from dataclasses import dataclass

_QUOTES = str.maketrans(
    {
        "\u2018": "'",
        "\u2019": "'",
        "\u201b": "'",
        "\u2032": "'",
        "\u201c": '"',
        "\u201d": '"',
        "\u2033": '"',
        "\u2010": "-",
        "\u2011": "-",
        "\u2012": "-",
        "\u2013": "-",
        "\u2014": "-",
        "\u2212": "-",
        "\uff5c": "|",
        "\uff1a": ":",
    }
)

_MARKER = re.compile(
    r"official\s+(?:hd\s+|4k\s+)?(?:music\s+)?video|official\s+mv\b|[(\[]\s*music\s+video\s*[)\]]|\bmusic\s+video\b"
)
_OFFICIAL_MUSIC_VIDEO = re.compile(r"official\s+(?:hd\s+|4k\s+)?music\s+video")
# Bracket groups that only describe the upload, not the song; dropped from the file name.
_VIDEO_TAG = re.compile(
    r"official|music\s+video|\bvideo\b|\bhd\b|\b4k\b|remaster|\bmv\b|explicit|\bclean\b|\bedited\b|closed\s+caption"
)
_FEAT = re.compile(r"^(?:feat\.?|ft\.?|featuring|with)\s", re.IGNORECASE)
_FEAT_WORD = re.compile(r"^(?:feat\.?|ft\.?|featuring)\s+", re.IGNORECASE)
# "Song ft. X", "Song feat. X (Remix)": an unbracketed credit, up to the next bracket group.
_TRAILING_FEAT = re.compile(r"\s+(?:feat\.?|ft\.?|featuring)\s+([^(\[\x00]+?)\s*(?=[(\[\x00]|$)", re.IGNORECASE)
_LIVE_PHRASE = re.compile(r"\blive\s+(?:at|from|in|on|session|performance|version)\b")
_BRACKETS = re.compile(r"\s*[(\[]([^)\]]*)[)\]]")
_UNSAFE = re.compile(r'[<>"?*\x00-\x1f]')
# Jellyfin stacks "Name Part 2", "Name - CD 1", "Name (Disc 3)" as parts of one video; a Roman numeral is not stacked.
_STACK_PART = re.compile(r"(?i)(?<=[\s_.\-(\[])(cd|dvd|part|pt\.?|dis[ck])([\s_.\-]*)(\d{1,2})([)\]]?)$")
_ROMAN = ["", "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "XI", "XII", "XIII", "XIV", "XV",
          "XVI", "XVII", "XVIII", "XIX", "XX"]  # fmt: skip
_ARTIST_COLON = re.compile(r"^([^:()\[\]]+):\s+(.+)$")


@dataclass(frozen=True)
class Decision:
    accepted: bool
    reason: str
    song: str = ""
    key: str = ""
    rank: float = 0.0


def normalize_text(text: str) -> str:
    return unicodedata.normalize("NFKC", str(text or "")).translate(_QUOTES).strip()


def _fold(text: str) -> str:
    """Lower-case, accent-free, alphanumeric-only form used for comparisons."""
    decomposed = unicodedata.normalize("NFKD", normalize_text(text).lower())
    return re.sub(r"[^a-z0-9]+", "", "".join(c for c in decomposed if not unicodedata.combining(c)))


def _artist_forms(artist: str) -> set[str]:
    folded = _fold(artist)
    forms = {folded}
    if folded.startswith("the"):
        forms.add(folded[3:])
    return {f for f in forms if f}


def song_key(song: str) -> str:
    """Key used to spot two uploads of the same song: no featured artists, brackets or punctuation."""
    without_feat = re.sub(
        r"\s*[(\[]\s*(?:feat\.?|ft\.?|featuring|with)\s[^)\]]*[)\]]", "", normalize_text(song), flags=re.I
    )
    without_feat = re.sub(r"\s+(?:feat\.?|ft\.?|featuring)\s.*$", "", without_feat, flags=re.I)
    return _fold(_BRACKETS.sub("", without_feat)) or _fold(without_feat)


def _split_dashes(text: str) -> list[str]:
    """Split on " - " outside brackets, so "Song (Official Video - 4K)" stays one part."""
    parts: list[str] = []
    depth = 0
    start = 0
    i = 0
    while i < len(text):
        char = text[i]
        if char in "([":
            depth += 1
        elif char in ")]":
            depth = max(0, depth - 1)
        elif depth == 0 and text.startswith(" - ", i):
            parts.append(text[start:i].strip())
            start = i + 3
            i += 3
            continue
        i += 1
    parts.append(text[start:].strip())
    return [part for part in parts if part]


def _has_bracketed_marker(text: str) -> bool:
    return any(_MARKER.search(group.lower()) for group in _BRACKETS.findall(text))


def split_title(title: str, artist: str) -> tuple[str, bool, list[str]]:
    """Return (song, has_artist_prefix, qualifiers) for an upload title.

    "The Struts - Somebody New (Official Video) | Live 2019" -> ("Somebody New (Official Video)", True,
    ["Official Video", "Live 2019"]). The artist prefix may include collaborators ("Artist, X - Song").
    """
    text = normalize_text(title)
    qualifiers: list[str] = []
    if "|" in text:
        parts = [p.strip() for p in text.split("|") if p.strip()]
        main = next((p for p in parts if " - " in p), parts[0] if parts else text)
        qualifiers.extend(p for p in parts if p is not main)
        text = main

    segments = _split_dashes(text)
    has_prefix = False
    forms = _artist_forms(artist)
    if len(segments) > 1 and any(_fold(segments[0]).startswith(form) for form in forms):
        has_prefix = True
        segments = segments[1:]
    elif len(segments) == 1 and (colon := _ARTIST_COLON.match(segments[0])):
        # "Paramore: Misery Business [OFFICIAL VIDEO]"
        if any(_fold(colon.group(1)).startswith(form) for form in forms):
            has_prefix = True
            segments = [colon.group(2).strip()]

    # "Other Artist - Song (Official Video)": the leading part names a collaborator, not the song. Only a
    # bracketed marker counts, since "Song - Artist One-Take Music Video" is a song with an uploader credit.
    if not has_prefix and len(segments) > 1 and _has_bracketed_marker(segments[1]):
        qualifiers.extend([segments[0], *segments[2:]])
        text = segments[1]
    else:
        # "Song - Behind The Scenes", "Song - Live at ..." -> the trailing parts are qualifiers.
        qualifiers.extend(segments[1:])
        text = segments[0]

    qualifiers.extend(m.group(1).strip() for m in _BRACKETS.finditer(text))
    return text.strip().strip('"').strip(), has_prefix, qualifiers


def file_safe(text: str) -> str:
    """Make a name safe for a file or folder, keeping word boundaries.

    ": " becomes " - " ("Star Wars: Episode I" -> "Star Wars - Episode I"); a slash or backslash between
    phrases becomes " - " ("Run Away With Me/Your Type") and between single words "-" ("AC/DC" -> "AC-DC");
    "|" becomes " - "; characters Windows and SMB reject (<>"?*) are dropped.
    """
    text = re.sub(r"\s*:\s+|\s+:\s*", " - ", text)
    text = text.replace(":", "-").replace("|", " - ")
    parts = re.split(r"[/\\]", text)
    if len(parts) > 1:
        stripped = [p.strip() for p in parts if p.strip()]
        text = (" - " if any(" " in p for p in stripped) else "-").join(stripped)
    text = _UNSAFE.sub("", text)
    text = re.sub(r"(?:\s*-\s*){2,}", " - ", text)
    return re.sub(r"\s+", " ", text).strip(" .-")


def _normalize_featuring(text: str) -> str:
    """One style for featured artists: "Song (feat. X)", whether the upload said "ft. X", "[feat X]" or
    "featuring X". Credits inside another bracket ("(Extended Remix featuring X)") are left alone."""

    def bracketed(match: re.Match) -> str:
        inner = match.group(1).strip()
        if _FEAT_WORD.match(inner):
            return f" (feat. {_FEAT_WORD.sub('', inner).strip()})"
        return match.group(0)

    text = _BRACKETS.sub(bracketed, text)
    # Look for an unbracketed credit only: blank out bracket groups (same length, so offsets still match).
    masked = re.sub(r"[(\[][^)\]]*[)\]]", lambda m: "\x00" * len(m.group(0)), text)
    trailing = _TRAILING_FEAT.search(masked)
    if trailing:
        credit = text[trailing.start(1) : trailing.end(1)].strip()
        text = f"{text[: trailing.start()]} {text[trailing.end() :].strip()}".strip()
        text = f"{text} (feat. {credit})"
    return re.sub(r"\s+", " ", text).strip()


def _unstack_part(text: str) -> str:
    """'Self-Titled, Part 2' -> 'Self-Titled, Part II', so Jellyfin does not stack the parts into one video."""

    def roman(match: re.Match) -> str:
        number = int(match.group(3))
        if not 0 < number < len(_ROMAN):
            return match.group(0)
        return f"{match.group(1)}{match.group(2) or ' '}{_ROMAN[number]}{match.group(4)}"

    return _STACK_PART.sub(roman, text)


def clean_song_title(song: str) -> str:
    """The file-safe song name: upload tags ("Official Video", "HD") dropped, featured artists as "(feat. X)"."""

    def keep(match: re.Match) -> str:
        inner = match.group(1)
        return "" if _VIDEO_TAG.search(inner.lower()) and not _FEAT.match(inner.strip()) else match.group(0)

    cleaned = _BRACKETS.sub(keep, normalize_text(song))
    cleaned = _normalize_featuring(cleaned)
    cleaned = file_safe(cleaned)
    return _unstack_part(cleaned)


def classify(
    entry: dict,
    artist: str,
    *,
    is_vevo: bool,
    exclude_keywords: list[str],
    exclude_qualifiers: list[str],
    min_duration: int,
    max_duration: int,
    members: Iterable[str] = (),
    require_marker: bool = True,
) -> Decision:
    title = normalize_text(entry.get("title") or "")
    lower = title.lower()
    if not title:
        return Decision(False, "no_title")
    if entry.get("live_status") in ("is_live", "is_upcoming", "post_live", "was_live"):
        return Decision(False, f"live_status_{entry.get('live_status')}")
    for keyword in exclude_keywords:
        if keyword and keyword in lower:
            return Decision(False, f"excluded:{keyword}")

    song, has_prefix, qualifiers = split_title(title, artist)
    if _LIVE_PHRASE.search(lower):
        return Decision(False, "excluded:live")
    qualifier_text = " ".join(q.lower() for q in qualifiers)
    for word in exclude_qualifiers:
        if word and re.search(rf"\b{re.escape(word)}\b", qualifier_text):
            return Decision(False, f"excluded_qualifier:{word}")

    duration = entry.get("duration")
    if not duration:
        return Decision(False, "no_duration")
    if duration < min_duration or duration > max_duration:
        return Decision(False, f"duration_{int(duration)}s")

    marker = bool(_MARKER.search(lower))
    featured = any(_FEAT.match(q) for q in qualifiers)
    if require_marker and not marker and not featured and not (is_vevo and has_prefix):
        return Decision(False, "no_music_video_marker")

    clean = clean_song_title(song)
    key = song_key(clean)
    if not clean or not key:
        return Decision(False, "no_song_title")
    # "Carly Rae Jepsen - Carly Rae Jepsen (VEVO LIFT)", "a-ha - Morten Harket": a promo or a member's solo
    # upload, not a song.
    if key in _artist_forms(artist) or key in {_fold(m) for m in members if m}:
        return Decision(False, "song_is_artist_name")

    rank = 3.0 if _OFFICIAL_MUSIC_VIDEO.search(lower) else 2.0 if marker else 1.0
    if is_vevo:
        rank += 0.5
    if any(re.search(r"\bclean\b", q.lower()) for q in qualifiers):
        rank -= 0.25
    return Decision(True, "music_video", clean, key, rank)


def select_videos(candidates: list[tuple[dict, Decision]]) -> list[tuple[dict, Decision]]:
    """Keep the best accepted upload per song: highest rank, then most views."""
    best: dict[str, tuple[dict, Decision]] = {}
    for entry, decision in candidates:
        if not decision.accepted:
            continue
        current = best.get(decision.key)
        score = (decision.rank, entry.get("view_count") or 0)
        if current is None or score > (current[1].rank, current[0].get("view_count") or 0):
            best[decision.key] = (entry, decision)
    return list(best.values())
