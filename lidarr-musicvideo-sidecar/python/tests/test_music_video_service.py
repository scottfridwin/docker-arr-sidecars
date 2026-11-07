#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

import json
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from music_video_downloader import library, repair, service, youtube
from music_video_downloader.config import Config, parse_interval
from music_video_downloader.state import State

STRUTS = {"artistName": "The Struts", "foreignArtistId": "mbid-struts", "monitored": True, "tags": []}
RHCP = {"artistName": "Red Hot Chili Peppers", "foreignArtistId": "mbid-rhcp", "monitored": True, "tags": []}

STRUTS_VEVO = youtube.Channel(
    url="https://www.youtube.com/user/thestrutsvevo",
    name="TheStrutsVEVO",
    channel_id="UCvevo",
    entries=[
        {"id": "vid-somebody", "title": "The Struts - Somebody New", "duration": 258, "view_count": 10},
        {"id": "vid-tatler", "title": "The Struts - Tatler Magazine", "duration": 184, "view_count": 10},
        {"id": "vid-lyric", "title": "The Struts - Hands On Me (Lyric Video)", "duration": 215, "view_count": 10},
        {"id": "vid-kiss", "title": "The Struts - Kiss This (Official Video)", "duration": 246, "view_count": 10},
    ],
)


def make_cfg(tmp: str, **overrides) -> Config:
    base = Path(tmp)
    values = {
        "library_path": base / "library",
        "state_dir": base / "state",
        "work_dir": base / "work",
        "download_delay": 0,
        "max_downloads_per_run": 10,
    }
    values.update(overrides)
    return Config(**values)


def fake_download(video_id: str, cfg: Config):
    cfg.work_dir.mkdir(parents=True, exist_ok=True)
    video = cfg.work_dir / f"{video_id}.mkv"
    video.write_bytes(b"video")
    thumb = cfg.work_dir / f"{video_id}.jpg"
    thumb.write_bytes(b"jpg")
    return video, thumb, {"upload_date": "20160512", "channel": "TheStrutsVEVO"}


class LibraryTests(unittest.TestCase):
    def test_existing_videos_reads_file_names_and_nfo_ids(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp) / "The Struts"
            folder.mkdir()
            (folder / "The Struts - Somebody New.mkv").touch()
            (folder / "Kiss This.webm").touch()
            (folder / "Kiss This-poster.jpg").touch()
            library.write_nfo(folder / "Kiss This.nfo", title="Kiss This", artist="The Struts", video_id="yt1", info={})
            (folder / "broken.nfo").write_text("<musicvideo>", encoding="utf-8")
            keys, ids = library.existing_videos(folder, "The Struts")
            self.assertEqual(keys, {"somebodynew", "kissthis"})
            self.assertEqual(ids, {"yt1"})

    def test_write_nfo_for_jellyfin(self):
        with tempfile.TemporaryDirectory() as tmp:
            nfo = Path(tmp) / "Song.nfo"
            library.write_nfo(
                nfo,
                title="Song & Dance",
                artist="AC/DC",
                video_id="abc",
                info={"upload_date": "20160512", "channel": "C"},
            )
            root = ET.parse(nfo).getroot()  # noqa: S314 - NFO written by the test
            self.assertEqual(root.tag, "musicvideo")
            self.assertEqual(root.findtext("title"), "Song & Dance")
            self.assertEqual(root.findtext("artist"), "AC/DC")
            self.assertEqual(root.findtext("year"), "2016")
            self.assertEqual(root.findtext("premiered"), "2016-05-12")
            self.assertEqual(root.find("uniqueid").attrib, {"type": "youtube", "default": "true"})

    def test_install_moves_video_and_poster_and_refuses_to_overwrite(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            video, thumb = base / "id.mkv", base / "id.jpg"
            video.write_bytes(b"v")
            thumb.write_bytes(b"j")
            target = library.install(video, thumb, base / "AC_DC", "Thunder: Struck?")
            self.assertEqual(target, base / "AC_DC" / "Thunder - Struck.mkv")
            self.assertTrue((base / "AC_DC" / "Thunder - Struck-poster.jpg").is_file())
            self.assertEqual(
                sorted(p.name for p in (base / "AC_DC").iterdir()),
                ["Thunder - Struck-poster.jpg", "Thunder - Struck.mkv"],
            )
            again = base / "id2.mkv"
            again.write_bytes(b"v")
            with self.assertRaises(FileExistsError):
                library.install(again, None, base / "AC_DC", "Thunder - Struck")

    def test_safe_name(self):
        self.assertEqual(library.safe_name("AC/DC"), "AC-DC")
        self.assertEqual(library.safe_name(" ... "), "Unknown")
        self.assertEqual(library.safe_name("a\u2010ha"), "a-ha")
        self.assertEqual(library.safe_name("\u201cWeird Al\u201d Yankovic"), "Weird Al Yankovic")
        self.assertEqual(library.legacy_safe_name("\u201cWeird Al\u201d Yankovic"), "\u201cWeird Al\u201d Yankovic")

    def test_nfo_has_genres_mbid_and_lockdata_and_is_not_rewritten_when_unchanged(self):
        with tempfile.TemporaryDirectory() as tmp:
            nfo = Path(tmp) / "Song.nfo"
            fields = {
                "title": "Song",
                "artist": "a\u2010ha",
                "video_id": "yt1",
                "info": {"upload_date": "19850101", "channel": "a-ha"},
                "artist_mbid": "mbid-aha",
                "genres": ["Synth-pop", "Pop"],
            }
            self.assertTrue(library.write_nfo(nfo, **fields))
            root = ET.parse(nfo).getroot()  # noqa: S314 - NFO written by the test
            self.assertEqual(root.findtext("artist"), "a\u2010ha")  # exact name, so Jellyfin links the artist
            self.assertEqual([g.text for g in root.iter("genre")], ["Synth-pop", "Pop"])
            self.assertEqual(root.findtext("lockdata"), "true")
            self.assertEqual(
                {u.get("type"): u.text for u in root.iter("uniqueid")},
                {"youtube": "yt1", "musicbrainzartist": "mbid-aha"},
            )
            self.assertFalse(library.write_nfo(nfo, **fields))
            self.assertEqual(library.nfo_video_id(nfo), "yt1")

    def test_nfo_video_id_reads_jellyfin_youtubeid(self):
        with tempfile.TemporaryDirectory() as tmp:
            nfo = Path(tmp) / "Song.nfo"
            nfo.write_text("<musicvideo><title>Song</title><youtubeid>yt9</youtubeid></musicvideo>", encoding="utf-8")
            self.assertEqual(library.nfo_video_id(nfo), "yt9")
            self.assertEqual(library.nfo_video_id(Path(tmp) / "missing.nfo"), "")

    def test_move_video_takes_companions_and_refuses_to_overwrite(self):
        with tempfile.TemporaryDirectory() as tmp:
            old, new = Path(tmp) / "a\u2010ha", Path(tmp) / "a-ha"
            old.mkdir()
            for name in ("Take On Me.mkv", "Take On Me.nfo", "Take On Me-poster.jpg", "Take On Me.en.srt", "Other.mkv"):
                (old / name).write_bytes(b"x")
            moved = library.move_video(old / "Take On Me.mkv", new, "Take On Me (Remastered)")
            self.assertEqual(moved, new / "Take On Me (Remastered).mkv")
            self.assertEqual(
                sorted(p.name for p in new.iterdir()),
                [
                    "Take On Me (Remastered)-poster.jpg",
                    "Take On Me (Remastered).en.srt",
                    "Take On Me (Remastered).mkv",
                    "Take On Me (Remastered).nfo",
                ],
            )
            self.assertEqual([p.name for p in old.iterdir()], ["Other.mkv"])
            with self.assertRaises(FileExistsError):
                library.move_video(old / "Other.mkv", new, "Take On Me (Remastered)")
            self.assertTrue((old / "Other.mkv").is_file())


class ConfigTests(unittest.TestCase):
    def test_parse_interval(self):
        self.assertEqual(parse_interval("24h"), 86400)
        self.assertEqual(parse_interval("none"), 0)
        with self.assertRaises(ValueError):
            parse_interval("daily")


class ServiceTests(unittest.TestCase):
    def run_service(self, cfg, artists, channels, *, download=fake_download, members=None):
        state = State(cfg.state_file)
        with (
            patch.object(service, "lidarr_artists", return_value=artists),
            patch.object(service.musicbrainz, "artist_channels", side_effect=lambda mbid, _: channels.get(mbid, [])),
            patch.object(
                service.musicbrainz, "artist_members", side_effect=lambda mbid, _: (members or {}).get(mbid, [])
            ),
            patch.object(service.youtube, "list_channel", side_effect=lambda url, _: STRUTS_VEVO),
            patch.object(service.youtube, "download", side_effect=download) as mock_download,
            patch.object(service.youtube, "fetch_metadata", side_effect=AssertionError("unexpected lookup")),
        ):
            stats = service.run_once(cfg, state)
        return stats, state, mock_download

    def test_channel_linked_twice_is_used_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = make_cfg(tmp, dry_run=True)
            urls = [STRUTS_VEVO.url, "https://www.youtube.com/channel/UCvevo"]
            with patch.object(service, "music_videos_for", wraps=service.music_videos_for) as spy:
                self.run_service(cfg, [STRUTS], {"mbid-struts": urls})
            self.assertEqual(len(spy.call_args.args[1]), 1)

    def test_downloads_new_music_videos_and_skips_existing(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = make_cfg(tmp)
            folder = cfg.library_path / "The Struts"
            folder.mkdir(parents=True)
            (folder / "The Struts - Tatler Magazine.mkv").touch()  # added by hand earlier

            stats, state, mock_download = self.run_service(cfg, [STRUTS, RHCP], {"mbid-struts": [STRUTS_VEVO.url]})

            self.assertEqual(sorted(c.args[0] for c in mock_download.call_args_list), ["vid-kiss", "vid-somebody"])
            self.assertEqual((stats.downloaded, stats.failed, stats.artists_without_channel), (2, 0, 1))
            self.assertTrue((folder / "Somebody New.mkv").is_file())
            self.assertTrue((folder / "Somebody New-poster.jpg").is_file())
            self.assertEqual(ET.parse(folder / "Kiss This.nfo").getroot().findtext("uniqueid"), "vid-kiss")  # noqa: S314 - NFO written by the service under test
            saved = json.loads(cfg.state_file.read_text(encoding="utf-8"))
            self.assertEqual(saved["videos"]["vid-kiss"]["status"], "downloaded")
            self.assertIn("mbid-struts", saved["artists"])
            self.assertIn("mbid-rhcp", saved["artists"])

            # Next run: both artists were just checked, nothing happens.
            stats, _, mock_download = self.run_service(cfg, [STRUTS, RHCP], {"mbid-struts": [STRUTS_VEVO.url]})
            mock_download.assert_not_called()
            self.assertEqual(stats.artists_checked, 0)

    def test_download_limit_stops_run_and_artist_is_resumed(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = make_cfg(tmp, max_downloads_per_run=1)
            for run in range(3):
                stats, state, mock_download = self.run_service(cfg, [STRUTS], {"mbid-struts": [STRUTS_VEVO.url]})
                self.assertEqual((stats.downloaded, len(mock_download.call_args_list)), (1, 1))
                # Marked as checked only once all three of its videos are in.
                self.assertEqual("mbid-struts" in state.artists, run == 2)
            self.assertEqual(len(list((cfg.library_path / "The Struts").glob("*.mkv"))), 3)

    def test_failed_download_is_retried_until_threshold(self):
        def broken(video_id, cfg):
            raise RuntimeError("Sign in to confirm you're not a bot")

        with tempfile.TemporaryDirectory() as tmp:
            cfg = make_cfg(tmp, max_attempts=2, artist_recheck_days=0)
            for expected_calls in (3, 3, 0):
                stats, state, mock_download = self.run_service(
                    cfg, [STRUTS], {"mbid-struts": [STRUTS_VEVO.url]}, download=broken
                )
                self.assertEqual(len(mock_download.call_args_list), expected_calls)
            self.assertEqual(state.videos["vid-kiss"]["attempts"], 2)
            self.assertIn("not a bot", state.videos["vid-kiss"]["error"])
            self.assertFalse(list(cfg.library_path.rglob("*.mkv")))

    def test_download_writes_full_nfo_and_caches_upload_metadata(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = make_cfg(tmp)
            struts = {**STRUTS, "genres": ["Rock", "Glam Rock"]}
            _, state, _ = self.run_service(cfg, [struts], {"mbid-struts": [STRUTS_VEVO.url]})
            root = ET.parse(cfg.library_path / "The Struts" / "Kiss This.nfo").getroot()  # noqa: S314 - NFO written by the service under test
            self.assertEqual([g.text for g in root.iter("genre")], ["Rock", "Glam Rock"])
            self.assertEqual(root.findtext("studio"), "TheStrutsVEVO")
            self.assertEqual(root.findtext("lockdata"), "true")
            entry = state.videos["vid-kiss"]
            self.assertEqual((entry["poster"], entry["repaired"]), ("youtube", repair.REPAIR_VERSION))
            self.assertEqual(entry["meta"]["upload_date"], "20160512")

    def test_band_member_upload_is_not_downloaded(self):
        member_channel = youtube.Channel(
            url="u",
            name="TheStrutsVEVO",
            entries=[{"id": "vid-luke", "title": "The Struts - Luke Spiller (Official Video)", "duration": 200}],
        )
        with tempfile.TemporaryDirectory() as tmp:
            cfg = make_cfg(tmp)
            with (
                patch.object(service, "lidarr_artists", return_value=[STRUTS]),
                patch.object(service.musicbrainz, "artist_channels", return_value=["u"]),
                patch.object(service.musicbrainz, "artist_members", return_value=["Luke Spiller"]),
                patch.object(service.youtube, "list_channel", return_value=member_channel),
                patch.object(service.youtube, "download") as mock_download,
            ):
                stats = service.run_once(cfg, State(cfg.state_file))
            mock_download.assert_not_called()
            self.assertEqual(stats.selected, 0)

    def test_videos_still_in_the_old_artist_folder_are_not_downloaded_again(self):
        old_name = {**STRUTS, "artistName": "The Struts\u2019"}  # folder "The Struts’" before, "The Struts'" now
        with tempfile.TemporaryDirectory() as tmp:
            cfg = make_cfg(tmp, repair=False)
            legacy = cfg.library_path / "The Struts\u2019"
            legacy.mkdir(parents=True)
            for stem in ("Somebody New", "Tatler Magazine", "Kiss This"):
                (legacy / f"{stem}.mkv").touch()  # added by hand: not in state
            _, _, mock_download = self.run_service(cfg, [old_name], {"mbid-struts": [STRUTS_VEVO.url]})
            mock_download.assert_not_called()

    def test_dry_run_reports_without_downloading_or_saving_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = make_cfg(tmp, dry_run=True)
            stats, state, mock_download = self.run_service(cfg, [STRUTS], {"mbid-struts": [STRUTS_VEVO.url]})
            mock_download.assert_not_called()
            self.assertEqual(len(stats.planned), 3)
            self.assertFalse(cfg.state_file.exists())
            report = next(cfg.state_dir.glob("dry-run-*.md")).read_text(encoding="utf-8")
            self.assertIn("| The Struts | Kiss This | The Struts - Kiss This (Official Video) |", report)


class RepairTests(unittest.TestCase):
    AHA = {"artistName": "a\u2010ha", "foreignArtistId": "mbid-aha", "monitored": True, "genres": ["Synth-pop"]}
    BASE_UPLOADS = {
        "yt-take": {"title": "a-ha - Take On Me (Official Video) [4K]", "upload_date": "20100106", "channel": "a-ha"},
        "yt-morten": {"title": "a-ha - Morten Harket (Official Video)", "upload_date": "20120101", "channel": "a-ha"},
        "yt-hunter": {"title": "a-ha - Hunter In The Hills / Live", "upload_date": "20130101", "channel": "a-ha"},
    }

    def setUp(self):
        self.UPLOADS = {k: dict(v) for k, v in self.BASE_UPLOADS.items()}

    def make_library(self, cfg):
        # As 4.2 left it: old folder name, Jellyfin-rewritten NFOs without <artist>, frame-grab posters.
        folder = cfg.library_path / "a\u2010ha"
        folder.mkdir(parents=True)
        for stem, video_id in (("Take On Me", "yt-take"), ("Morten Harket", "yt-morten")):
            (folder / f"{stem}.mkv").write_bytes(b"v")
            (folder / f"{stem}-poster.jpg").write_bytes(b"frame grab")
            (folder / f"{stem}.nfo").write_text(
                f"<musicvideo><title>{stem}</title><youtubeid>{video_id}</youtubeid></musicvideo>", encoding="utf-8"
            )
        (folder / "Hand Added.mkv").write_bytes(b"v")
        return folder

    def fake_metadata(self, video_id, cfg, *, thumbnail):
        thumb = None
        if thumbnail:
            cfg.work_dir.mkdir(parents=True, exist_ok=True)
            thumb = cfg.work_dir / f"{video_id}.jpg"
            thumb.write_bytes(b"youtube thumb")
        return {**self.UPLOADS[video_id], "duration": 230}, thumb

    def run_repair(self, cfg, state, lookup=None):
        with (
            patch.object(repair.musicbrainz, "artist_members", return_value=["Morten Harket"]),
            patch.object(repair.youtube, "fetch_metadata", side_effect=lookup or self.fake_metadata) as mock_lookup,
        ):
            stats = repair.run([self.AHA], cfg, state)
        return stats, mock_lookup

    def test_repair_moves_renames_rewrites_and_flags(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = make_cfg(tmp, repair_delay=0)
            self.make_library(cfg)
            state = State(cfg.state_file)
            stats, mock_lookup = self.run_repair(cfg, state)

            new = cfg.library_path / "a-ha"
            self.assertFalse((cfg.library_path / "a\u2010ha").exists())  # emptied and removed
            self.assertEqual(
                sorted(p.name for p in new.iterdir()),
                [
                    "Hand Added.mkv",
                    "Morten Harket-poster.jpg",
                    "Morten Harket.mkv",
                    "Morten Harket.nfo",
                    "Take On Me-poster.jpg",
                    "Take On Me.mkv",
                    "Take On Me.nfo",
                ],
            )
            self.assertEqual((new / "Take On Me-poster.jpg").read_bytes(), b"youtube thumb")
            root = ET.parse(new / "Take On Me.nfo").getroot()  # noqa: S314 - NFO written by the repair
            self.assertEqual(
                (root.findtext("artist"), root.findtext("year"), root.findtext("genre")),
                ("a\u2010ha", "2010", "Synth-pop"),
            )
            self.assertEqual((stats.checked, stats.lookups, stats.posters, stats.flagged), (2, 2, 2, 1))
            # A band member's upload is kept but listed.
            self.assertIn("song_is_artist_name", state.videos["yt-morten"]["flag"])
            report = (cfg.state_dir / "repair-report.md").read_text(encoding="utf-8")
            self.assertIn("Morten Harket.mkv", report)
            self.assertNotIn("Hand Added", report)

            # Second run: everything is cached; no lookups, nothing rewritten.
            stats, mock_lookup = self.run_repair(cfg, State(cfg.state_file))
            mock_lookup.assert_not_called()
            self.assertEqual((stats.checked, stats.renamed, stats.nfos, stats.posters), (2, 0, 0, 0))

    def test_repair_renames_to_current_title_rules(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = make_cfg(tmp, repair_delay=0)
            folder = cfg.library_path / "a-ha"
            folder.mkdir(parents=True)
            (folder / "Hunter In The Hills Live.mkv").write_bytes(b"v")
            library.write_nfo(
                folder / "Hunter In The Hills Live.nfo", title="x", artist="a-ha", video_id="yt-hunter", info={}
            )
            self.UPLOADS["yt-hunter"]["title"] = "a-ha: Hunter In The Hills ft. Someone [Official Video]"
            state = State(cfg.state_file)
            self.run_repair(cfg, state)
            self.assertTrue((folder / "Hunter In The Hills (feat. Someone).mkv").is_file())
            self.assertTrue((folder / "Hunter In The Hills (feat. Someone).nfo").is_file())

    def test_repair_does_not_require_a_music_video_marker(self):
        # The video was selected once (e.g. a plain "Artist - Song" on the VEVO channel); its upload's channel
        # field is the artist's name, so the repair must not re-apply the marker rule.
        with tempfile.TemporaryDirectory() as tmp:
            cfg = make_cfg(tmp, repair_delay=0)
            folder = cfg.library_path / "a-ha"
            folder.mkdir(parents=True)
            (folder / "Living Daylights.mkv").write_bytes(b"v")
            library.write_nfo(folder / "Living Daylights.nfo", title="x", artist="a-ha", video_id="yt-hunter", info={})
            self.UPLOADS["yt-hunter"] = {"title": "a-ha - The Living Daylights", "channel": "a-ha"}
            state = State(cfg.state_file)
            stats, _ = self.run_repair(cfg, state)
            self.assertEqual(stats.flagged, 0)
            self.assertTrue((folder / "The Living Daylights.mkv").is_file())

    def test_failed_lookup_keeps_what_the_nfo_already_says(self):
        def broken(video_id, cfg, *, thumbnail):
            raise RuntimeError("Video unavailable")

        with tempfile.TemporaryDirectory() as tmp:
            cfg = make_cfg(tmp, repair_delay=0)
            folder = cfg.library_path / "a-ha"
            folder.mkdir(parents=True)
            (folder / "Take On Me.mkv").write_bytes(b"v")
            library.write_nfo(
                folder / "Take On Me.nfo",
                title="Take On Me",
                artist="a-ha",
                video_id="yt-take",
                info={"upload_date": "19850101", "channel": "a-ha VEVO"},
            )
            self.run_repair(cfg, State(cfg.state_file), lookup=broken)
            root = ET.parse(folder / "Take On Me.nfo").getroot()  # noqa: S314 - NFO written by the repair
            self.assertEqual(
                (root.findtext("title"), root.findtext("premiered"), root.findtext("studio"), root.findtext("artist")),
                ("Take On Me", "1985-01-01", "a-ha VEVO", "a\u2010ha"),
            )

    def test_one_failing_file_does_not_stop_the_repair(self):
        real_move = library.move_video

        def flaky_move(video, directory, stem):
            if video.stem == "Take On Me":
                raise PermissionError(13, "Permission denied")
            return real_move(video, directory, stem)

        with tempfile.TemporaryDirectory() as tmp:
            cfg = make_cfg(tmp, repair_delay=0)
            self.make_library(cfg)
            with patch.object(repair.library, "move_video", side_effect=flaky_move):
                stats, _ = self.run_repair(cfg, State(cfg.state_file))
            state = State(cfg.state_file)  # saved despite the error
            self.assertIn("repair failed", state.videos["yt-take"]["flag"])
            self.assertTrue((cfg.library_path / "a-ha" / "Morten Harket.mkv").is_file())
            self.assertEqual(stats.failed, 1)
            self.assertTrue((cfg.state_dir / "repair-report.md").is_file())

    def test_artists_sharing_a_folder_only_repair_their_own_videos(self):
        twin = {"artistName": "a-ha", "foreignArtistId": "mbid-other", "monitored": True, "genres": ["Metal"]}
        with tempfile.TemporaryDirectory() as tmp:
            cfg = make_cfg(tmp, repair_delay=0)
            folder = cfg.library_path / "a-ha"
            folder.mkdir(parents=True)
            for stem, video_id in (
                ("Take On Me", "yt-take"),
                ("Other Song", "yt-other"),
            ):
                (folder / f"{stem}.mkv").write_bytes(b"v")
                library.write_nfo(folder / f"{stem}.nfo", title=stem, artist="a-ha", video_id=video_id, info={})
            state = State(cfg.state_file)
            state.record_video(
                "yt-take", "downloaded", artist="mbid-aha", meta=self.UPLOADS["yt-take"], poster="youtube"
            )
            state.record_video("yt-other", "downloaded", artist="mbid-other", meta={"title": "a-ha - Other Song"},
                               poster="youtube")  # fmt: skip
            for name in ("Take On Me", "Other Song"):
                (folder / f"{name}-poster.jpg").write_bytes(b"p")
            with (
                patch.object(repair.musicbrainz, "artist_members", return_value=[]),
                patch.object(repair.youtube, "fetch_metadata", side_effect=AssertionError("unexpected lookup")),
            ):
                repair.run([self.AHA, twin], cfg, state)
                genres = {
                    s: ET.parse(folder / f"{s}.nfo").getroot().findtext("genre")  # noqa: S314 - written by the repair
                    for s in ("Take On Me", "Other Song")
                }
                self.assertEqual(genres, {"Take On Me": "Synth-pop", "Other Song": "Metal"})
                # A second run writes nothing: the artists don't take turns rewriting each other's NFOs.
                stats = repair.run([self.AHA, twin], cfg, state)
            self.assertEqual(stats.nfos, 0)

    def test_rename_clash_is_flagged_not_overwritten(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = make_cfg(tmp, repair_delay=0)
            folder = self.make_library(cfg)
            (cfg.library_path / "a-ha").mkdir()
            (cfg.library_path / "a-ha" / "Take On Me.mkv").write_bytes(b"other")
            state = State(cfg.state_file)
            self.run_repair(cfg, state)
            self.assertTrue((folder / "Take On Me.mkv").is_file())
            self.assertEqual((cfg.library_path / "a-ha" / "Take On Me.mkv").read_bytes(), b"other")
            self.assertIn("not renamed", state.videos["yt-take"]["flag"])

    def test_lookup_limit_and_failures(self):
        def broken(video_id, cfg, *, thumbnail):
            raise RuntimeError("Video unavailable")

        with tempfile.TemporaryDirectory() as tmp:
            cfg = make_cfg(tmp, repair_delay=0, repair_max_per_run=1, max_attempts=2)
            self.make_library(cfg)
            stats, mock_lookup = self.run_repair(cfg, State(cfg.state_file), lookup=broken)
            self.assertEqual((stats.lookups, stats.failed), (1, 1))
            for _ in range(4):
                stats, _ = self.run_repair(cfg, State(cfg.state_file), lookup=broken)
            # Each video is looked up at most max_attempts times; then the repair keeps its name and NFO.
            state = State(cfg.state_file)
            self.assertEqual({v["lookup_attempts"] for v in state.videos.values()}, {2})
            stats, mock_lookup = self.run_repair(cfg, state, lookup=broken)
            mock_lookup.assert_not_called()


class YoutubeDownloadTests(unittest.TestCase):
    def test_single_file_fallback_that_stays_mp4_is_still_found(self):
        class FakeYDL:
            def __init__(self, opts):
                self.opts = opts

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

            def extract_info(self, url, download):
                work = Path(self.opts["paths"]["home"])
                (work / "abc.mp4").write_bytes(b"v")
                return {"id": "abc"}

        with tempfile.TemporaryDirectory() as tmp, patch.dict(sys.modules, {"yt_dlp": type(sys)("yt_dlp")}):
            sys.modules["yt_dlp"].YoutubeDL = FakeYDL
            cfg = make_cfg(tmp)
            video, thumb, _ = youtube.download("abc", cfg)
            self.assertEqual((video.name, thumb), ("abc.mp4", None))


class LidarrArtistTests(unittest.TestCase):
    def test_tag_filter_and_placeholder_artist(self):
        artists = [
            {**STRUTS, "tags": [7]},
            {**RHCP, "tags": []},
            {"artistName": "Unmonitored", "foreignArtistId": "x", "monitored": False, "tags": [7]},
            {
                "artistName": "Various Artists",
                "foreignArtistId": "89ad4ac3-39f7-470e-963a-56509c546377",
                "monitored": True,
                "tags": [7],
            },
        ]
        responses = {"artist": artists, "tag": [{"id": 7, "label": "MusicVideos"}]}
        last = {}

        def fake_request(method, path, payload=None):
            last["path"] = path

        with (
            patch.object(service, "arr_api_request", side_effect=fake_request),
            patch.object(service, "get_state", side_effect=lambda key: responses[last["path"]]),
            tempfile.TemporaryDirectory() as tmp,
        ):
            names = [a["artistName"] for a in service.lidarr_artists(make_cfg(tmp, artist_tag="musicvideos"))]
            self.assertEqual(names, ["The Struts"])
            names = [a["artistName"] for a in service.lidarr_artists(make_cfg(tmp))]
            self.assertEqual(names, ["The Struts", "Red Hot Chili Peppers"])
            self.assertEqual(service.lidarr_artists(make_cfg(tmp, artist_tag="missing")), [])


if __name__ == "__main__":
    unittest.main()
