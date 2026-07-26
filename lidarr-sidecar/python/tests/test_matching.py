import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from deemix_downloader import matching, musicbrainz_api
from deemix_downloader.config import Config


class MatchingTests(unittest.TestCase):
    def test_fetch_musicbrainz_release_requests_release_group_data(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            cfg = Config()
            cfg.work_path = Path(tmpdir)
            with patch.object(musicbrainz_api, "cfg", cfg), patch.object(
                musicbrainz_api,
                "call_musicbrainz_api",
                return_value={},
            ) as mock_call:
                musicbrainz_api.fetch_musicbrainz_release("example-mbid")

        self.assertTrue(mock_call.called)
        requested_url = mock_call.call_args.args[0]
        self.assertIn("inc=recordings+release-groups+url-rels", requested_url)

    def test_find_best_match_uses_release_group_aliases(self):
        def fake_get_deezer_album_info(album_id: str):
            return {
                "id": album_id,
                "title": "The Long Sleep of Bob 1200-1532",
                "nb_tracks": 13,
                "explicit_lyrics": False,
                "release_date": "1999-12-31",
                "upc": "00123",
            }

        candidate = matching.ReleaseCandidate(
            title="1200-1532 the Long Sleep of Bob",
            alternate_titles=["The Long Sleep of Bob 1200-1532"],
            track_count=13,
            deezer_album_id="12345",
            release_status="Official",
            musicbrainz_barcode="123",
        )

        with patch.object(matching, "get_deezer_album_info", side_effect=fake_get_deezer_album_info):
            result = matching.find_best_match([candidate], "1200-1532 the Long Sleep of Bob", set())

        self.assertTrue(result.matched)
        self.assertEqual(result.deezer_title, "The Long Sleep of Bob 1200-1532")
        self.assertFalse(result.was_redirected)

    def test_find_best_match_blocks_redirected_when_gate_enabled(self):
        def fake_get_deezer_album_info(album_id: str):
            return {
                "id": "200",
                "title": "Example Album",
                "nb_tracks": 10,
                "explicit_lyrics": False,
                "release_date": "2001-01-01",
                "upc": "123456789012",
            }

        candidate = matching.ReleaseCandidate(
            title="Example Album",
            track_count=10,
            deezer_album_id="100",
            release_status="Official",
            musicbrainz_barcode="123456789012",
        )

        with (
            patch.object(matching, "get_deezer_album_info", side_effect=fake_get_deezer_album_info),
            patch.object(matching.cfg, "require_non_redirect_deezer", True),
            patch.object(matching.cfg, "require_upc_match", True),
        ):
            result = matching.find_best_match(
                [candidate],
                "Example Album",
                set(),
            )

        self.assertFalse(result.matched)

    def test_find_best_match_allows_redirected_when_gate_disabled(self):
        def fake_get_deezer_album_info(album_id: str):
            return {
                "id": "901",
                "title": "Fallback Album",
                "nb_tracks": 8,
                "explicit_lyrics": False,
                "release_date": "1998-01-01",
                "upc": "000098765432",
            }

        candidate = matching.ReleaseCandidate(
            title="Fallback Album",
            track_count=8,
            deezer_album_id="900",
            release_status="Official",
            musicbrainz_barcode="98765432",
        )

        with (
            patch.object(matching, "get_deezer_album_info", side_effect=fake_get_deezer_album_info),
            patch.object(matching.cfg, "require_non_redirect_deezer", False),
            patch.object(matching.cfg, "require_upc_match", True),
        ):
            result = matching.find_best_match([candidate], "Fallback Album", set())

        self.assertTrue(result.matched)
        self.assertEqual(result.deezer_album_id, "901")
        self.assertTrue(result.was_redirected)
        self.assertIn("redirected Deezer ID", result.reason)

    def test_find_best_match_rejects_when_upc_mismatch(self):
        def fake_get_deezer_album_info(album_id: str):
            return {
                "id": album_id,
                "title": "UPC Check",
                "nb_tracks": 5,
                "explicit_lyrics": False,
                "release_date": "2010-01-01",
                "upc": "999999999999",
            }

        candidate = matching.ReleaseCandidate(
            title="UPC Check",
            track_count=5,
            deezer_album_id="123",
            release_status="Official",
            musicbrainz_barcode="111111111111",
        )

        with (
            patch.object(matching, "get_deezer_album_info", side_effect=fake_get_deezer_album_info),
            patch.object(matching.cfg, "require_non_redirect_deezer", False),
            patch.object(matching.cfg, "require_upc_match", True),
        ):
            result = matching.find_best_match([candidate], "UPC Check", set())

        self.assertFalse(result.matched)


if __name__ == "__main__":
    unittest.main()
