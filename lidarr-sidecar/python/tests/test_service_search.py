import sys
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from deemix_downloader import service
from deemix_downloader.matching import MatchResult, ReleaseCandidate


class ServiceSearchTests(unittest.TestCase):
    @staticmethod
    def indexer_release():
        return {
            "deezer_album_id": "42",
            "deezer_title": "Test Album",
            "year": "2001",
            "track_count": 1,
            "release_id": "12",
            "release_foreign_id": "release-mbid",
            "artist_name": "Test Artist",
            "artist_id": "11",
            "artist_foreign_id": "artist-mbid",
            "album_title": "Test Album",
            "album_foreign_id": "group-mbid",
            "album_id": "22",
            "lidarr_download_ids": ["lidarr-download-id"],
        }

    def test_search_builds_and_matches_without_download_side_effects(self):
        album = {"title": "Test Album!", "releaseDate": "2001-02-03"}
        candidates = [ReleaseCandidate(deezer_album_id="42")]
        result = MatchResult(
            matched=True,
            deezer_album_id="42",
            lidarr_release_id="12",
            lidarr_release_foreign_id="release-mbid",
        )
        with (
            patch.object(service, "_build_candidates", return_value=candidates) as build,
            patch.object(service, "find_best_match", return_value=result) as match,
            patch.object(service, "_download_album") as download,
            patch.object(service, "_write_result_file") as write_result,
            patch.object(service, "_upsert_missing_file") as write_missing,
        ):
            actual = service.search_album(album)

        self.assertIs(actual, result)
        build.assert_called_once_with(album, "2001")
        match.assert_called_once_with(candidates, "Test Album", set())
        download.assert_not_called()
        write_result.assert_not_called()
        write_missing.assert_not_called()

    def test_polling_can_keep_its_failed_album_filter(self):
        failed = {"42"}
        with (
            patch.object(service, "_build_candidates", return_value=[]) as build,
            patch.object(service, "find_best_match", return_value=MatchResult()) as match,
        ):
            service.search_album({"title": "Album", "releaseDate": None}, failed)

        build.assert_called_once_with({"title": "Album", "releaseDate": None}, "")
        match.assert_called_once_with([], "Album", failed)

    def test_text_artist_search_returns_matching_albums(self):
        artist = {"id": 11, "artistName": "Taylor Swift"}
        albums = [{"id": 22}, {"id": 23}]
        release = self.indexer_release()
        with (
            patch.object(service, "_find_indexer_artists", return_value=[artist]) as find_artist,
            patch.object(service, "_indexer_artist_albums", return_value=albums) as find_albums,
            patch.object(service, "_indexer_match_album", side_effect=[release, None]) as match,
        ):
            actual = service.search_indexer_releases(
                artist="", album="", q="Taylor Swift", year=None, request_type="search"
            )
        self.assertEqual(actual, [release])
        find_artist.assert_called_once_with("Taylor Swift")
        find_albums.assert_called_once_with(artist)
        self.assertEqual(
            match.call_args_list, [unittest.mock.call(albums[0], None), unittest.mock.call(albums[1], None)]
        )

    def test_text_artist_search_year_and_artist_name_ending_in_year(self):
        artist = {"id": 11}
        for query, matching_name, expected_year in (
            ("Taylor Swift 2025", "Taylor Swift", 2025),
            ("Band 2025", "Band 2025", None),
        ):
            with (
                self.subTest(query=query),
                patch.object(
                    service,
                    "_find_indexer_artists",
                    side_effect=lambda name, wanted=matching_name: [artist] if name == wanted else [],
                ),
                patch.object(service, "_indexer_artist_albums", return_value=[{"id": 22}]),
                patch.object(service, "_indexer_match_album", return_value=self.indexer_release()) as match,
            ):
                service.search_indexer_releases(artist="", album="", q=query, year=None, request_type="search")
                match.assert_called_once_with({"id": 22}, expected_year)

    def test_text_album_search_still_tries_artist_album_boundaries(self):
        artist = {"id": 11}
        album = {"id": 22}
        release = self.indexer_release()
        with (
            patch.object(
                service, "_find_indexer_artists", side_effect=lambda name: [artist] if name == "Taylor Swift" else []
            ),
            patch.object(service, "_indexer_artist_albums", return_value=[album]),
            patch.object(service, "resolve_album", return_value=album) as resolve,
            patch.object(service, "_indexer_match_album", return_value=release),
        ):
            actual = service.search_indexer_releases(
                artist="", album="", q="Taylor Swift The Life of a Showgirl 2025", year=None, request_type="search"
            )
        self.assertEqual(actual, [release])
        resolve.assert_called_once_with([album], "Taylor Swift", "The Life of a Showgirl", year=2025)

    def test_text_artist_search_rejects_duplicate_artist_names(self):
        with (
            patch.object(service, "_find_indexer_artists", return_value=[{"id": 1}, {"id": 2}]),
            self.assertRaises(service.AmbiguousAlbumError),
        ):
            service.search_indexer_releases(artist="", album="", q="Taylor Swift", year=None, request_type="search")

    def test_indexer_import_clears_the_correlated_lidarr_queue_item(self):
        on_download_complete = Mock()
        with (
            patch.object(service, "_download_album", return_value=True),
            patch.object(service, "remove_lidarr_queue_items") as remove_queue_items,
        ):
            imported = service.download_indexer_release(
                self.indexer_release(),
                on_download_complete,
                "test-token",
            )

        self.assertTrue(imported)
        remove_queue_items.assert_called_once_with(["lidarr-download-id"])

    def test_failed_indexer_import_keeps_the_lidarr_queue_item(self):
        with (
            patch.object(service, "_download_album", return_value=False),
            patch.object(service, "remove_lidarr_queue_items") as remove_queue_items,
        ):
            imported = service.download_indexer_release(
                self.indexer_release(),
                Mock(),
                "test-token",
            )

        self.assertFalse(imported)
        remove_queue_items.assert_not_called()


if __name__ == "__main__":
    unittest.main()
