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
