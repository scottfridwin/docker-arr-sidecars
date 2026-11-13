import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from deemix_downloader import service
from deemix_downloader.matching import MatchResult, ReleaseCandidate


class ServiceSearchTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
