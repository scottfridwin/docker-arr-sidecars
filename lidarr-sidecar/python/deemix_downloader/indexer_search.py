#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

"""Resolve Lidarr's raw Newznab album search text to an unambiguous album."""

from __future__ import annotations

import re
import unicodedata
from collections.abc import Iterable
from typing import Any


class AmbiguousAlbumError(ValueError):
    """Multiple Lidarr albums have the same search terms."""


def _search_key(value: str) -> str:
    # Lidarr's Newznab request generator changes literal plus signs to spaces.
    return " ".join(unicodedata.normalize("NFKC", value).replace("+", " ").casefold().split())


def _album_search_key(value: str) -> str:
    key = _search_key(value)
    return key.removeprefix("the ")


def matches_search_text(name: str, query: str) -> bool:
    """Match raw text or Lidarr's older cleaned Newznab query conservatively."""
    name_key = _search_key(name)
    query_key = _search_key(query)
    if name_key == query_key:
        return True
    title = "VA" if name == "Various Artists" else name
    title = re.sub(r"^the\s", "", title, flags=re.IGNORECASE)
    title = re.sub(r"[`\u00b4\u2018\u2019]", "'", title)
    title = re.sub(r"[^\w']+", " ", title)
    title = "".join(c for c in unicodedata.normalize("NFD", title) if unicodedata.category(c) != "Mn")
    return _search_key(title) == query_key


def resolve_album(
    albums: Iterable[dict[str, Any]], artist: str, album: str, *, year: int | None = None
) -> dict[str, Any] | None:
    """Resolve a raw artist/album query; refuse ambiguous or incomplete matches.

    The caller must advertise a raw audio search engine to Lidarr and provide
    albums from the complete local library, not just the wanted list.
    """
    artist_key = _search_key(artist)
    album_key = _album_search_key(album)
    if not artist_key or not album_key:
        return None

    matches = []
    for candidate in albums:
        artist_data = candidate.get("artist")
        if not isinstance(artist_data, dict):
            continue
        artist_name = artist_data.get("artistName")
        title = candidate.get("title")
        disambiguation = candidate.get("disambiguation") or ""
        if not all(isinstance(value, str) for value in (artist_name, title, disambiguation)):
            continue
        title_with_disambiguation = f"{title} {disambiguation}" if disambiguation.strip() else title
        if not matches_search_text(artist_name, artist):
            continue
        if _album_search_key(title_with_disambiguation) != album_key and not matches_search_text(
            title_with_disambiguation, album
        ):
            continue
        if year is not None:
            release_date = candidate.get("releaseDate")
            if not isinstance(release_date, str) or release_date[:4] != str(year):
                continue
        matches.append(candidate)

    if len(matches) > 1:
        raise AmbiguousAlbumError("Artist and album terms match multiple Lidarr albums")
    return matches[0] if matches else None
