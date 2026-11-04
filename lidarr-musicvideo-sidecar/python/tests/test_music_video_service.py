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

from music_video_downloader import library, service, youtube
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
            self.assertEqual(target, base / "AC_DC" / "Thunder Struck.mkv")
            self.assertTrue((base / "AC_DC" / "Thunder Struck-poster.jpg").is_file())
            self.assertEqual(
                sorted(p.name for p in (base / "AC_DC").iterdir()), ["Thunder Struck-poster.jpg", "Thunder Struck.mkv"]
            )
            again = base / "id2.mkv"
            again.write_bytes(b"v")
            with self.assertRaises(FileExistsError):
                library.install(again, None, base / "AC_DC", "Thunder Struck")

    def test_safe_name(self):
        self.assertEqual(library.safe_name("AC/DC"), "ACDC")
        self.assertEqual(library.safe_name(" ... "), "Unknown")


class ConfigTests(unittest.TestCase):
    def test_parse_interval(self):
        self.assertEqual(parse_interval("24h"), 86400)
        self.assertEqual(parse_interval("none"), 0)
        with self.assertRaises(ValueError):
            parse_interval("daily")


class ServiceTests(unittest.TestCase):
    def run_service(self, cfg, artists, channels, *, download=fake_download):
        state = State(cfg.state_file)
        with (
            patch.object(service, "lidarr_artists", return_value=artists),
            patch.object(service.musicbrainz, "artist_channels", side_effect=lambda mbid, _: channels.get(mbid, [])),
            patch.object(service.youtube, "list_channel", side_effect=lambda url, _: STRUTS_VEVO),
            patch.object(service.youtube, "download", side_effect=download) as mock_download,
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

    def test_dry_run_reports_without_downloading_or_saving_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = make_cfg(tmp, dry_run=True)
            stats, state, mock_download = self.run_service(cfg, [STRUTS], {"mbid-struts": [STRUTS_VEVO.url]})
            mock_download.assert_not_called()
            self.assertEqual(len(stats.planned), 3)
            self.assertFalse(cfg.state_file.exists())
            report = next(cfg.state_dir.glob("dry-run-*.md")).read_text(encoding="utf-8")
            self.assertIn("| The Struts | Kiss This | The Struts - Kiss This (Official Video) |", report)


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
