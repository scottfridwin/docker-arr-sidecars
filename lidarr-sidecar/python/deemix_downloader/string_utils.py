#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

"""String utilities for album/track title normalization and comparison."""

from __future__ import annotations

import re

# Roman numeral pattern for validation
_ROMAN_PATTERN = re.compile(
    r"^M{0,3}(CM|CD|D?C{0,3})(XC|XL|L?X{0,3})(IX|IV|V?I{0,3})$"
)
_ROMAN_VALUES = {"I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000}

# Edition patterns to remove (ordered by specificity - most specific first)
_EDITION_PATTERNS = [
    "super deluxe version",
    "super deluxe edition",
    "deluxe edition",
    "deluxe version",
    "super deluxe",
    "deluxe",
    "collector's edition",
    "platinum edition",
    "special edition",
    "limited edition",
    "expanded edition",
    "remastered",
    "anniversary edition",
    "original motion picture soundtrack",
    "soundtrack from the motion picture",
    "soundtrack",
]

# Ordinal pattern for anniversary/remaster removal
_ORDINAL_RE = re.compile(
    r"(\d+(?:st|nd|rd|th)|first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth"
    r"|eleventh|twelfth|thirteenth|fourteenth|fifteenth|sixteenth|seventeenth|eighteenth"
    r"|nineteenth|twentieth)",
    re.IGNORECASE,
)

# Track modifier patterns
_TRACK_MODIFIERS = [
    "live acoustic",
    "live",
    "acoustic",
    "remix",
    "radio edit",
    "edit",
    "version",
    "instrumental",
    "demo",
    "explicit",
    "clean",
]

# Feature/parody strip patterns
_FEATURE_PAREN_RE = re.compile(
    r"\s*\("
    r"(?:feat\.?|ft\.?|featuring|duet\s+with|with|parody\s+of"
    r"|an\s+adaptation\s+of|lyrical\s+adapt(?:ation|ion)\s+of)"
    r"[^)]*\)",
    re.IGNORECASE,
)
_FEATURE_DASH_RE = re.compile(
    r"\s*[-–—]\s*"
    r"(?:feat\.?|ft\.?|featuring|duet\s+with|with|parody\s+of"
    r"|an\s+adaptation\s+of|lyrical\s+adapt(?:ation|ion)\s+of)"
    r"\s+.*$",
    re.IGNORECASE,
)
_FEATURE_BARE_RE = re.compile(
    r"\s+(?:feat\.?|ft\.?|featuring|duet\s+with)\s+.*$", re.IGNORECASE
)
_FEATURE_WITH_RE = re.compile(r"\s+with\s+[A-Z]\S+.*$")
_FEATURE_PARODY_RE = re.compile(
    r"\s+(?:parody|an\s+adaptation|lyrical\s+adapt(?:ation|ion))\s+of\s+\"[^\"]+\".*$",
    re.IGNORECASE,
)


def roman_to_int(s: str) -> int | None:
    """Convert a Roman numeral string to integer. Returns None if invalid."""
    upper = s.upper()
    if not _ROMAN_PATTERN.match(upper):
        return None
    total = 0
    prev = 0
    for ch in reversed(upper):
        value = _ROMAN_VALUES[ch]
        if value < prev:
            total -= value
        else:
            total += value
        prev = value
    return total


def normalize_string(s: str) -> str:
    """Normalize a string for comparison (matches bash normalize_string behavior)."""
    if not s:
        return ""

    # Smart quotes → plain, dashes → hyphen, special chars
    replacements = {
        "\u2018": "'", "\u2019": "'",  # smart single quotes
        "\u201c": '"', "\u201d": '"',  # smart double quotes
        "\u2013": "-", "\u2010": "-",  # en dash, hyphen
        "\u00ba": "\u00b0",            # masculine ordinal → degree
        "&": "and",
        "\u2026": "...",               # ellipsis
        "\xa0": " ",                   # non-breaking space
    }
    for old, new in replacements.items():
        s = s.replace(old, new)

    # Remove parentheses, ?, !, commas, colons
    s = re.sub(r"[()?,!:,]", "", s)

    # Collapse whitespace and trim
    s = re.sub(r"\s+", " ", s).strip()

    # Replace Roman numerals with integers
    words = s.split(" ")
    result_words = []
    for word in words:
        if word and re.fullmatch(r"[MDCLXVI]+", word):
            num = roman_to_int(word)
            if num is not None:
                result_words.append(str(num))
            else:
                result_words.append(word)
        else:
            result_words.append(word)

    return " ".join(result_words)


def remove_punctuation(s: str) -> str:
    """Remove common punctuation characters."""
    return re.sub(r"[.,:;!?*'''\u2018\u2019\u201c\u201d\"\u0027\u2014-]", "", s)


def remove_quotes(s: str) -> str:
    """Remove quote characters."""
    return re.sub(r"['''\u2018\u2019\u201c\u201d\"]", "", s)


def clean_path_string(s: str) -> str:
    """Clean a string for safe use in file/folder names.

    Preserves Unicode letters (accents, CJK, etc.) and most punctuation
    that is safe on filesystems. Only removes characters that are illegal
    on Linux/Windows filesystems or cause parsing issues.
    """
    s = s.strip()
    # Replace filesystem-illegal chars (Linux: /, Windows: \ : * ? < > |)
    s = re.sub(r'[/\\:*?<>|]', "_", s)
    # Remove control characters and non-printable
    s = "".join(c for c in s if c.isprintable())
    # Collapse multiple spaces/underscores
    s = re.sub(r"[\s_]+", " ", s).strip()
    return s[:200]


def levenshtein_distance(s1: str, s2: str) -> int:
    """Calculate Levenshtein distance between two strings."""
    if not s1:
        return len(s2)
    if not s2:
        return len(s1)

    len1, len2 = len(s1), len(s2)

    # Use single-row optimization
    prev = list(range(len2 + 1))
    for i in range(1, len1 + 1):
        curr = [i] + [0] * len2
        for j in range(1, len2 + 1):
            cost = 0 if s1[i - 1] == s2[j - 1] else 1
            curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
        prev = curr

    return prev[len2]


def calculate_priority(input_str: str, prefs: str) -> int:
    """
    Determine priority for a string based on preference list.
    Returns lowest matching priority index, or 999 if no match.
    """
    BLANK = "__BLANK__"

    # Parse input tokens (comma-separated)
    input_tokens = []
    for t in (input_str or "").split(","):
        t = t.strip().strip('"').strip()
        input_tokens.append(t.lower() if t else BLANK)
    if not input_tokens:
        input_tokens = [BLANK]

    # Parse preference groups (comma-separated groups, pipe-separated alternatives)
    priority_map: dict[str, int] = {}
    prio = 0
    for group in (prefs or "").split(","):
        if not group:
            continue
        tokens = []
        for t in group.split("|"):
            t = t.strip().strip('"').strip()
            normalized = BLANK if t.lower() == "[blank]" else t.lower()
            tokens.append(normalized)
        for tok in tokens:
            if tok and tok not in priority_map:
                priority_map[tok] = prio
        prio += 1

    # Find best (lowest) priority
    best = 999
    for tok in input_tokens:
        if tok in priority_map and priority_map[tok] < best:
            best = priority_map[tok]
    return best



