import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from deemix_downloader.indexer_search import AmbiguousAlbumError, resolve_album


class IndexerSearchTests(unittest.TestCase):
    def setUp(self):
        self.album = {
            "id": 10,
            "title": "Björk + Friends",
            "disambiguation": "Live",
            "releaseDate": "2004-01-01",
            "artist": {"id": 2, "artistName": "The Artist"},
        }

    def test_raw_search_decodes_plus_and_unicode(self):
        result = resolve_album([self.album], "the artist", "Bjo\u0308rk   Friends Live")
        self.assertIs(result, self.album)

    def test_disambiguation_is_required(self):
        self.assertIsNone(resolve_album([self.album], "The Artist", "Björk Friends"))

    def test_duplicate_matches_are_rejected(self):
        other = {**self.album, "id": 11}
        with self.assertRaises(AmbiguousAlbumError):
            resolve_album([self.album, other], "The Artist", "Björk Friends Live")

    def test_year_can_disambiguate_and_unknown_year_does_not_match(self):
        other = {**self.album, "id": 11, "releaseDate": "2006-01-01"}
        self.assertIs(resolve_album([self.album, other], "The Artist", "Björk Friends Live", year=2004), self.album)
        self.assertIsNone(
            resolve_album([{**self.album, "releaseDate": None}], "The Artist", "Björk Friends Live", year=2004)
        )

    def test_empty_and_malformed_input_does_not_match(self):
        self.assertIsNone(resolve_album([self.album], "", "Björk Friends Live"))
        self.assertIsNone(resolve_album([{**self.album, "artist": None}], "The Artist", "Björk Friends Live"))
        self.assertIsNone(resolve_album([{**self.album, "disambiguation": 123}], "The Artist", "Björk Friends Live"))


if __name__ == "__main__":
    unittest.main()
