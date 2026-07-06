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
            }

        candidate = matching.ReleaseCandidate(
            title="1200-1532 the Long Sleep of Bob",
            alternate_titles=["The Long Sleep of Bob 1200-1532"],
            track_count=13,
            deezer_album_id="12345",
            release_status="Official",
        )

        with patch.object(matching, "get_deezer_album_info", side_effect=fake_get_deezer_album_info):
            result = matching.find_best_match([candidate], "1200-1532 the Long Sleep of Bob", set())

        self.assertTrue(result.matched)
        self.assertEqual(result.deezer_title, "The Long Sleep of Bob 1200-1532")


if __name__ == "__main__":
    unittest.main()
