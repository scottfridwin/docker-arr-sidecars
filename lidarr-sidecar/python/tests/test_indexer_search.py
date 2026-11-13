import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from deemix_downloader.indexer_search import AmbiguousAlbumError, matches_search_text, resolve_album


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

    def test_lidarr_cleaned_queries_match_but_raw_punctuation_is_preserved(self):
        self.assertTrue(matches_search_text("The Struts", "Struts"))
        self.assertTrue(matches_search_text("Björk & Friends", "Bjork Friends"))
        self.assertTrue(matches_search_text("Björk & Friends", "Björk & Friends"))
        self.assertTrue(matches_search_text("Various Artists", "VA"))
        self.assertFalse(matches_search_text("Struts", "The Struts"))

    def test_cleaned_album_matches_are_rejected_when_ambiguous(self):
        album = {**self.album, "title": "Café!", "disambiguation": ""}
        self.assertIs(resolve_album([album], "Artist", "Cafe"), album)
        other = {**album, "id": 11, "title": "Cafe"}
        with self.assertRaises(AmbiguousAlbumError):
            resolve_album([album, other], "Artist", "Cafe")

    def test_disambiguation_is_required(self):
        self.assertIsNone(resolve_album([self.album], "The Artist", "Björk Friends"))

    def test_duplicate_matches_are_rejected(self):
        other = {**self.album, "id": 11}
        with self.assertRaises(AmbiguousAlbumError):
            resolve_album([self.album, other], "The Artist", "Björk Friends Live")

    def test_lidarr_query_can_omit_leading_album_article(self):
        album = {**self.album, "title": "The Life of a Showgirl", "disambiguation": ""}
        self.assertIs(resolve_album([album], "The Artist", "Life of a Showgirl"), album)

    def test_article_normalization_rejects_ambiguous_albums(self):
        first = {**self.album, "title": "The Album", "disambiguation": ""}
        other = {**first, "id": 11, "title": "Album"}
        with self.assertRaises(AmbiguousAlbumError):
            resolve_album([first, other], "The Artist", "Album")

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
