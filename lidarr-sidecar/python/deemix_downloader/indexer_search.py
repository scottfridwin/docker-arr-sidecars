#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

"""Resolve Lidarr's raw Newznab album search text to an unambiguous album."""

from __future__ import annotations

import unicodedata
from collections.abc import Iterable
from typing import Any


class AmbiguousAlbumError(ValueError):
    """Multiple Lidarr albums have the same search terms."""


def _search_key(value: str) -> str:
    # Lidarr's Newznab request generator changes literal plus signs to spaces.
    return " ".join(unicodedata.normalize("NFKC", value).replace("+", " ").casefold().split())


def resolve_album(
    albums: Iterable[dict[str, Any]], artist: str, album: str, *, year: int | None = None
) -> dict[str, Any] | None:
    """Resolve a raw artist/album query; refuse ambiguous or incomplete matches.

    The caller must advertise a raw audio search engine to Lidarr and provide
    albums from the complete local library, not just the wanted list.
    """
    artist_key = _search_key(artist)
    album_key = _search_key(album)
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
        if _search_key(artist_name) != artist_key or _search_key(title_with_disambiguation) != album_key:
            continue
        if year is not None:
            release_date = candidate.get("releaseDate")
            if not isinstance(release_date, str) or release_date[:4] != str(year):
                continue
        matches.append(candidate)

    if len(matches) > 1:
        raise AmbiguousAlbumError("Artist and album terms match multiple Lidarr albums")
    return matches[0] if matches else None
