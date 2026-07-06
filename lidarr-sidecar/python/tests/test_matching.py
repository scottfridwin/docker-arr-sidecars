import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from deemix_downloader import matching


def test_find_best_match_uses_release_group_aliases(monkeypatch):
    def fake_get_deezer_album_info(album_id: str):
        return {
            "id": album_id,
            "title": "The Long Sleep of Bob 1200-1532",
            "nb_tracks": 13,
            "explicit_lyrics": False,
            "release_date": "1999-12-31",
        }

    monkeypatch.setattr(matching, "get_deezer_album_info", fake_get_deezer_album_info)

    candidate = matching.ReleaseCandidate(
        title="1200-1532 the Long Sleep of Bob",
        alternate_titles=["The Long Sleep of Bob 1200-1532"],
        track_count=13,
        deezer_album_id="12345",
        release_status="Official",
    )

    result = matching.find_best_match([candidate], "1200-1532 the Long Sleep of Bob", set())

    assert result.matched is True
    assert result.deezer_title == "The Long Sleep of Bob 1200-1532"
