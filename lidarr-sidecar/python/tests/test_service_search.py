import os
import sys
import unittest
from pathlib import Path
from unittest.mock import Mock, patch
from urllib.parse import quote_plus

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from deemix_downloader import service
from deemix_downloader.matching import MatchResult, ReleaseCandidate


class ServiceSearchTests(unittest.TestCase):
    def test_result_validation_stops_at_page_end_after_invalid_candidates(self):
        releases = [{**self.indexer_release(), "album_id": str(i), "album_title": f"Album {i}"} for i in range(1000)]
        albums = [{"id": i, "title": f"Album {i}", "artist": {"artistName": "Test Artist"}} for i in range(1000)]

        def title(_album, _albums, release):
            return None if release["album_id"] in {"0", "2"} else release["album_title"]

        with (
            patch.object(service, "_indexer_artist_albums", return_value=albums),
            patch.object(service, "_indexer_report_title", side_effect=title) as parse,
        ):
            page = service._validate_indexer_results(releases, 1, 2)
        self.assertEqual([item["album_id"] for item in page], ["3", "4"])
        self.assertEqual(parse.call_count, 5)

    def test_legacy_and_indexer_services_cannot_run_together(self):
        with (
            patch.dict(os.environ, {"SERVICE_INDEXER_ENABLED": "true"}, clear=True),
            self.assertRaisesRegex(RuntimeError, "cannot run together"),
        ):
            service._check_download_service_configuration()
        with patch.dict(
            os.environ, {"SERVICE_INDEXER_ENABLED": "true", "SERVICE_DEEMIXDOWNLOADER_ENABLED": "false"}, clear=True
        ):
            service._check_download_service_configuration()

    @staticmethod
    def indexer_release():
        return {
            "deezer_album_id": "42",
            "deezer_title": "Test Album",
            "year": "2001",
            "track_count": 1,
            "release_id": "12",
            "release_foreign_id": "release-mbid",
            "release_title": "Test Album",
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

    def test_build_candidates_uses_batched_release_metadata_and_only_fetches_needed_aliases(self):
        album = {
            "foreignAlbumId": "group",
            "releases": [
                {"id": 1, "foreignReleaseId": "unlinked", "title": "Album"},
                {"id": 2, "foreignReleaseId": "linked", "title": "Album", "trackCount": 10},
            ],
        }
        releases = {
            "unlinked": {"status": "Official", "release-group": {"id": "group"}},
            "linked": {
                "status": "Official",
                "barcode": "123",
                "release-group": {"id": "group"},
                "relations": [{"ended": False, "url": {"resource": "https://deezer.com/album/42"}}],
            },
        }
        with (
            patch.object(service.musicbrainz_api, "fetch_musicbrainz_group_releases", return_value=releases) as browse,
            patch.object(service, "fetch_musicbrainz_release") as fetch_release,
            patch.object(service, "fetch_musicbrainz_release_group", return_value={"aliases": []}) as fetch_group,
        ):
            candidates = service._build_candidates(album, "2025")
        browse.assert_called_once_with("group")
        fetch_release.assert_not_called()
        fetch_group.assert_called_once_with("group")
        self.assertEqual(candidates[1].deezer_album_id, "42")
        self.assertEqual(candidates[1].musicbrainz_barcode, "123")

    def test_build_candidates_uses_complete_release_cache_without_browsing(self):
        album = {"foreignAlbumId": "group", "releases": [{"id": 1, "foreignReleaseId": "release"}]}
        with (
            patch.object(service.musicbrainz_api, "cached_musicbrainz_release", return_value={"status": "Official"}),
            patch.object(service.musicbrainz_api, "fetch_musicbrainz_group_releases") as browse,
            patch.object(service, "fetch_musicbrainz_release") as fetch,
        ):
            candidates = service._build_candidates(album, "2025")
        self.assertEqual(len(candidates), 1)
        browse.assert_not_called()
        fetch.assert_not_called()

    def test_build_candidates_can_include_multiple_deezer_links_per_release(self):
        album = {"releases": [{"id": 1, "foreignReleaseId": "release", "title": "Album"}]}
        metadata = {
            "status": "Official",
            "relations": [
                {"ended": False, "url": {"resource": "https://deezer.com/album/42"}},
                {"ended": False, "url": {"resource": "https://deezer.com/album/43"}},
                {"ended": False, "url": {"resource": "https://deezer.com/album/42"}},
            ],
        }
        with patch.object(service.musicbrainz_api, "cached_musicbrainz_release", return_value=metadata):
            legacy = service._build_candidates(album, "2001")
            indexer = service._build_candidates(album, "2001", all_deezer_links=True)
        self.assertEqual([c.deezer_album_id for c in legacy], ["42"])
        self.assertEqual([c.deezer_album_id for c in indexer], ["42", "43"])

    def test_text_artist_search_returns_matching_albums(self):
        artist = {"id": 11, "artistName": "Taylor Swift"}
        albums = [{"id": 22}, {"id": 23}]
        release = self.indexer_release()
        with (
            patch.object(service, "_find_indexer_artists", return_value=[artist]) as find_artist,
            patch.object(service, "_indexer_artist_albums", return_value=albums) as find_albums,
            patch.object(service, "_indexer_match_album", side_effect=[[release], []]) as match,
        ):
            actual = service.search_indexer_releases(
                artist="", album="", q="Taylor Swift", year=None, request_type="search"
            )
        self.assertEqual(actual, [release])
        find_artist.assert_called_once_with("Taylor Swift")
        find_albums.assert_called_once_with(artist)
        self.assertEqual(
            match.call_args_list,
            [unittest.mock.call(albums[0], None, albums), unittest.mock.call(albums[1], None, albums)],
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
                patch.object(service, "_indexer_match_album", return_value=[self.indexer_release()]) as match,
            ):
                service.search_indexer_releases(artist="", album="", q=query, year=None, request_type="search")
                match.assert_called_once_with({"id": 22}, expected_year, [{"id": 22}])

    def test_numeric_album_title_takes_precedence_over_artist_year(self):
        artist = {"id": 11, "artistName": "Taylor Swift"}
        album = {"id": 22, "title": "1989", "artist": artist, "releaseDate": "2014-10-27"}
        release = self.indexer_release()
        with (
            patch.object(
                service, "_find_indexer_artists", side_effect=lambda name: [artist] if name == "Taylor Swift" else []
            ),
            patch.object(service, "_indexer_artist_albums", return_value=[album]),
            patch.object(service, "_indexer_match_album", return_value=[release]) as match,
        ):
            actual = service.search_indexer_releases(
                artist="", album="", q="Taylor Swift 1989", year=None, request_type="search"
            )
        self.assertEqual(actual, [release])
        match.assert_called_once_with(album, None, [album])

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
            patch.object(service, "_indexer_match_album", return_value=[release]),
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

    def test_struts_search_resolves_cleaned_name_and_refuses_collision(self):
        artist = {"id": 11, "artistName": "The Struts"}
        album = {"id": 22, "title": "Pretty Vicious", "artist": artist}
        release = self.indexer_release()
        with (
            patch.object(service, "_indexer_api_get", return_value=[artist]),
            patch.object(service, "_indexer_artist_albums", return_value=[album]),
            patch.object(service, "_warn_missing_artist_link"),
            patch.object(service, "_indexer_match_album", return_value=[release]),
        ):
            self.assertEqual(
                service.search_indexer_releases(
                    artist="", album="", q="Struts Pretty Vicious", year=None, request_type="search"
                ),
                [release],
            )
        with (
            patch.object(service, "_indexer_api_get", return_value=[artist, {"id": 12, "artistName": "Struts"}]),
            self.assertRaises(service.AmbiguousAlbumError),
        ):
            service.search_indexer_releases(artist="", album="", q="Struts", year=None, request_type="search")

    def test_artist_link_warning_does_not_block_linked_release(self):
        artist = {"artistName": "Artist", "foreignArtistId": "00000000-0000-0000-0000-000000000001"}
        with (
            patch.object(service.musicbrainz_api, "fetch_musicbrainz_artist", return_value={"relations": []}),
            patch.object(service.log, "warning") as warning,
        ):
            service._warn_missing_artist_link(artist)
        self.assertIn("No Deezer artist link", warning.call_args.args[0])
        with (
            patch.object(
                service.musicbrainz_api,
                "fetch_musicbrainz_artist",
                side_effect=service.musicbrainz_api.MusicBrainzUnavailable("unavailable"),
            ),
            patch.object(service.log, "warning") as warning,
        ):
            service._warn_missing_artist_link(artist)
        self.assertIn("Cannot check", warning.call_args.args[0])
        with (
            patch.object(
                service.musicbrainz_api,
                "fetch_musicbrainz_artist",
                return_value={"relations": [{"url": {"resource": "https://www.deezer.com/artist/123"}}]},
            ),
            patch.object(service.log, "warning") as warning,
        ):
            service._warn_missing_artist_link(artist)
        warning.assert_not_called()

        with (
            patch.object(service.musicbrainz_api, "fetch_musicbrainz_artist", return_value={"relations": []}),
            patch.object(service.log, "warning") as warning,
            patch.object(service, "_indexer_artist_albums", return_value=[{"id": 22}]),
            patch.object(service, "_indexer_match_album", return_value=[self.indexer_release()]),
        ):
            results = service._indexer_artist_releases([artist], None)
        self.assertEqual(len(results), 1)
        self.assertIn("No Deezer artist link", warning.call_args.args[0])

    def test_ambiguous_artist_album_split_is_rejected_before_fetching_releases(self):
        first = {"id": 1, "artistName": "The Band"}
        second = {"id": 2, "artistName": "Band Album"}
        albums = {
            1: [{"id": 10, "title": "Album Live", "artist": first}],
            2: [{"id": 20, "title": "Live", "artist": second}],
        }
        with (
            patch.object(service, "_indexer_api_get", return_value=[first, second]),
            patch.object(service, "_indexer_artist_albums", side_effect=lambda artist: albums[artist["id"]]),
            patch.object(service, "_indexer_match_album") as match,
            self.assertRaises(service.AmbiguousAlbumError),
        ):
            service.search_indexer_releases(artist="", album="", q="Band Album Live", year=None, request_type="search")
        match.assert_not_called()

    def test_report_title_preserves_parenthesized_album_name_and_uses_album_year(self):
        album = {
            "id": 22,
            "title": "Red (Taylor’s version)",
            "releaseDate": "2021-11-12",
            "artist": {"id": 11, "artistName": "Taylor Swift"},
        }
        response = {
            "parsedAlbumInfo": {"albumTitle": "Red Taylor’s version", "quality": {"quality": {"id": 0}}},
            "artist": {"id": 11},
            "albums": [{"id": 22}],
        }
        with patch.object(service, "_indexer_api_get", return_value=response) as parse:
            title = service._indexer_report_title(album, [album, {"id": 23, "title": "Red"}], self.indexer_release())
        self.assertIn("Taylor Swift - Red Taylor’s version (2021) - ", title)
        self.assertIn("Deezer 42", title)
        self.assertIn("Lidarr release 12", title)
        self.assertNotIn("release-mbid", title)
        parse.assert_called_once_with(f"parse?title={quote_plus(title)}")

    def test_report_title_rejects_wrong_mapping_and_criteria_conflicts(self):
        album = {"id": 22, "title": "Target", "artist": {"id": 11, "artistName": "Artist"}}
        response = {
            "parsedAlbumInfo": {"albumTitle": "Target", "quality": {"quality": {"id": 0}}},
            "artist": {"id": 11},
            "albums": [{"id": 23}],
        }
        with patch.object(service, "_indexer_api_get", return_value=response):
            self.assertIsNone(service._indexer_report_title(album, [album], self.indexer_release()))
        response["albums"] = [{"id": 22}]
        with patch.object(service, "_indexer_api_get", return_value=response):
            self.assertIsNone(
                service._indexer_report_title(album, [album, {"id": 23, "title": "Target"}], self.indexer_release())
            )

    def test_report_title_without_release_year_is_still_checked(self):
        album = {"id": 22, "title": "Target", "artist": {"id": 11, "artistName": "Artist"}}
        response = {
            "parsedAlbumInfo": {"albumTitle": "Target", "quality": {"quality": {"id": 0}}},
            "artist": {"id": 11},
            "albums": [{"id": 22}],
        }
        with patch.object(service, "_indexer_api_get", return_value=response):
            self.assertTrue(
                service._indexer_report_title(album, [album], self.indexer_release()).startswith(
                    "Artist - Target [Lidarr] - "
                )
            )

    def test_report_title_rejects_unverified_quality(self):
        album = {"id": 22, "title": "Target", "artist": {"id": 11, "artistName": "Artist"}}
        response = {
            "parsedAlbumInfo": {"albumTitle": "Target", "quality": {"quality": {"id": 1}}},
            "artist": {"id": 11},
            "albums": [{"id": 22}],
        }
        with patch.object(service, "_indexer_api_get", return_value=response):
            self.assertIsNone(service._indexer_report_title(album, [album], self.indexer_release()))

    def test_indexer_match_excludes_release_when_lidarr_cannot_map_title(self):
        album = {
            "id": 22,
            "title": "Target",
            "artist": {"id": 11, "artistName": "Artist"},
            "releases": [{"id": 12}],
        }
        match = MatchResult(matched=True, lidarr_release_id="12", deezer_album_id="42", deezer_track_count=1)
        with (
            patch.object(service, "get_album_data", return_value=album),
            patch.object(service, "_build_candidates", return_value=[]),
            patch.object(service, "find_all_matches", return_value=[match]),
            patch.object(service, "_indexer_api_get", return_value={}),
        ):
            self.assertEqual(service._indexer_match_album(album, None, [album]), [])

    def test_indexer_album_search_returns_every_validated_edition(self):
        album = {
            "id": 22,
            "title": "Test Album",
            "releaseDate": "2001-01-01",
            "artist": {"id": 11, "artistName": "Test Artist"},
            "releases": [{"id": 12, "title": "Test Album"}, {"id": 13, "title": "Test Album Deluxe"}],
        }
        matches = [
            MatchResult(
                matched=True,
                lidarr_release_id="12",
                lidarr_release_foreign_id="mb1",
                deezer_album_id="42",
                deezer_title="Test Album",
                deezer_track_count=10,
            ),
            MatchResult(
                matched=True,
                lidarr_release_id="13",
                lidarr_release_foreign_id="mb2",
                deezer_album_id="43",
                deezer_title="Test Album Deluxe",
                deezer_track_count=12,
            ),
        ]
        parsed = {
            "parsedAlbumInfo": {"albumTitle": "Test Album", "quality": {"quality": {"id": 0}}},
            "artist": {"id": 11},
            "albums": [{"id": 22}],
        }
        with (
            patch.object(service, "get_album_data", return_value=album),
            patch.object(service, "_build_candidates", return_value=[]),
            patch.object(service, "find_all_matches", return_value=matches),
            patch.object(service, "_indexer_api_get", return_value=parsed),
        ):
            results = service._indexer_match_album(album, None, [album])
        self.assertEqual([(r["release_id"], r["deezer_album_id"]) for r in results], [("12", "42"), ("13", "43")])
        self.assertIn("Test Album Deluxe", results[1]["report_title"])
        self.assertNotEqual(results[0]["report_title"], results[1]["report_title"])
        self.assertIn("Test Artist - Test Album (2001) - 10 tracks", results[0]["report_title"])

    def test_cached_results_are_rechecked_against_current_lidarr_library(self):
        release = self.indexer_release()
        album = {"id": 22, "title": "Test Album", "artist": {"id": 11, "artistName": "Test Artist"}}
        response = {
            "parsedAlbumInfo": {"albumTitle": "Test Album", "quality": {"quality": {"id": 0}}},
            "artist": {"id": 11},
            "albums": [{"id": 22}],
        }
        with (
            patch.object(service, "_indexer_artist_albums", return_value=[album, {"id": 23, "title": "Test Album"}]),
            patch.object(service, "_indexer_api_get", return_value=response),
        ):
            self.assertEqual(service._validate_indexer_results([release]), [])

        with (
            patch.object(service, "_indexer_artist_albums", return_value=[{**album, "title": "Renamed"}]),
            patch.object(service, "_indexer_api_get") as parse,
        ):
            self.assertEqual(service._validate_indexer_results([release]), [])
            parse.assert_not_called()

    def test_indexer_download_uses_strict_import_and_completion_callback(self):
        on_download_complete = Mock()
        with (
            patch.object(service, "_download_album", return_value=True) as download,
        ):
            imported = service.download_indexer_release(
                self.indexer_release(),
                on_download_complete,
                "test-token",
            )

        self.assertTrue(imported)
        self.assertTrue(download.call_args.kwargs["strict_manual_import"])
        self.assertIs(download.call_args.kwargs["on_download_complete"], on_download_complete)


if __name__ == "__main__":
    unittest.main()
