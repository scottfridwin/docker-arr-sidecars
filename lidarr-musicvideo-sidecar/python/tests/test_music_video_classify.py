#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from music_video_downloader.classify import classify, clean_song_title, select_videos, song_key, split_title
from music_video_downloader.config import DEFAULT_EXCLUDE_KEYWORDS, DEFAULT_EXCLUDE_QUALIFIERS
from music_video_downloader.musicbrainz import channel_urls

KEYWORDS = [k.strip() for k in DEFAULT_EXCLUDE_KEYWORDS.split(",")]
QUALIFIERS = [k.strip() for k in DEFAULT_EXCLUDE_QUALIFIERS.split(",")]


def decide(title, artist="The Struts", *, vevo=False, duration=220, **entry):
    return classify(
        {"title": title, "duration": duration, **entry},
        artist,
        is_vevo=vevo,
        exclude_keywords=KEYWORDS,
        exclude_qualifiers=QUALIFIERS,
        min_duration=90,
        max_duration=900,
    )


class ClassifyTests(unittest.TestCase):
    # Real titles from the artists' official channels (November 2026).
    ACCEPTED = [
        (
            "The Struts - Too Good At Raising Hell (Official Music Video)",
            "The Struts",
            False,
            "Too Good At Raising Hell",
        ),
        ("The Struts - Kiss This – Official Video", "The Struts", False, "Kiss This"),
        ("The Struts - Somebody New", "The Struts", True, "Somebody New"),
        ("The Struts, paris jackson - Low Key in Love (Official Music Video)", "The Struts", True, "Low Key in Love"),
        (
            "The Struts - Rock ‘n’ Roll Fantasy (Official Video) | Tribute to Bad Company",
            "The Struts",
            False,
            "Rock 'n' Roll Fantasy",
        ),
        (
            "The Struts - Could Have Been Me (feat. Brian May)",
            "The Struts",
            False,
            "Could Have Been Me (feat. Brian May)",
        ),
        (
            "Red Hot Chili Peppers - Californication (Official Music Video) [HD UPGRADE]",
            "Red Hot Chili Peppers",
            False,
            "Californication",
        ),
        ("Jack Sparrow (feat. Michael Bolton)", "The Lonely Island", False, "Jack Sparrow (feat. Michael Bolton)"),
        ("I'm A Weirdo - Conner4real One-Take Music Video", "The Lonely Island", False, "I'm A Weirdo"),
    ]

    REJECTED = [
        ("The Struts - Rock ‘n’ Roll Fantasy (Lyric Video) | Tribute to Bad Company", True, "excluded:lyric"),
        ("The Struts - Too Good At Raising Hell (Live Visualizer)", True, "excluded:visualizer"),
        ("The Struts - Can't Sleep (Official Audio)", False, "excluded:official audio"),
        ("The Struts - Pretty Vicious (Acoustic / Unplugged At EastWest)", True, "excluded:acoustic"),
        ("The Struts - Could Have Been Me (feat. Brian May) - Behind The Scenes", False, "excluded:behind the scenes"),
        ("The Struts - Kiss This (Live On Good Morning America's Summer Concert Series)", True, "excluded:live"),
        ("The Struts - Fire (Pt. 1/Live At The O2 Forum Kentish Town/London/UK/2019)", True, "excluded:live"),
        ("The Struts - Fire (Part 1/Audio)", True, "excluded_qualifier:audio"),
        ("The Struts - Freak Like You (Stripped Session)", True, "excluded_qualifier:session"),
        ("The Struts - Stop (Spice Girls Cover)", True, "excluded_qualifier:cover"),
        ("The Struts - Body Talks Tour (Episode 1)", True, "excluded_qualifier:episode"),
        ("Red Hot Chili Peppers - Hanalei [Vinyl Playback Video]", False, "excluded_qualifier:playback"),
        # A plain "Artist - Song" upload counts only on a VEVO channel.
        ("The Struts - Matter of Time", False, "no_music_video_marker"),
        ("#GMA 🕺🏻", False, "no_music_video_marker"),
    ]

    def test_accepts_music_videos(self):
        for title, artist, vevo, song in self.ACCEPTED:
            with self.subTest(title=title):
                decision = decide(title, artist, vevo=vevo)
                self.assertTrue(decision.accepted, decision.reason)
                self.assertEqual(decision.song, song)

    def test_rejects_other_uploads(self):
        for title, vevo, reason in self.REJECTED:
            with self.subTest(title=title):
                decision = decide(title, vevo=vevo)
                self.assertFalse(decision.accepted)
                self.assertEqual(decision.reason, reason)

    def test_live_in_song_title_is_not_a_live_upload(self):
        decision = decide("The Struts - Live Wire (Official Video)")
        self.assertTrue(decision.accepted, decision.reason)
        self.assertEqual(decision.song, "Live Wire")

    def test_duration_and_live_status_limits(self):
        self.assertEqual(decide("The Struts - Song (Official Video)", duration=14).reason, "duration_14s")
        self.assertEqual(decide("The Struts - Song (Official Video)", duration=None).reason, "no_duration")
        self.assertEqual(
            decide("The Struts - Song (Official Video)", live_status="is_upcoming").reason, "live_status_is_upcoming"
        )

    def test_select_prefers_official_music_video_then_views(self):
        entries = [
            {"id": "a", "title": "The Struts - Fallin' With Me", "duration": 180, "view_count": 900},
            {
                "id": "b",
                "title": "The Struts - Fallin’ With Me (Official Music Video)",
                "duration": 168,
                "view_count": 5,
            },
            {"id": "c", "title": "The Struts - Inside Your Mind (Official Video)", "duration": 231, "view_count": 1},
            {"id": "d", "title": "The Struts - Inside Your Mind (Official Video)", "duration": 231, "view_count": 50},
            {"id": "e", "title": "The Struts - Hands On Me (Lyric Video)", "duration": 215, "view_count": 10**6},
        ]
        decided = [(e, decide(e["title"], vevo=True, duration=e["duration"])) for e in entries]
        picked = sorted(e["id"] for e, _ in select_videos(decided))
        self.assertEqual(picked, ["b", "d"])

    def test_clean_version_ranks_below_uncensored(self):
        clean = decide("Like A Boss (ft. Seth Rogen) - Clean Version", "The Lonely Island")
        uncensored = decide("Like A Boss (ft. Seth Rogen) - Uncensored Version", "The Lonely Island")
        self.assertEqual(clean.key, uncensored.key)
        self.assertLess(clean.rank, uncensored.rank)


class TitleHelperTests(unittest.TestCase):
    def test_split_title_strips_artist_prefix_and_collects_qualifiers(self):
        song, has_prefix, qualifiers = split_title(
            "The Struts - Somebody New (Official Video) | Live 2019", "The Struts"
        )
        self.assertEqual(song, "Somebody New (Official Video)")
        self.assertTrue(has_prefix)
        self.assertEqual(qualifiers, ["Live 2019", "Official Video"])

    def test_split_title_without_leading_the(self):
        self.assertTrue(split_title("Struts - Somebody New", "The Struts")[1])

    def test_split_title_other_artist_is_not_a_prefix(self):
        self.assertFalse(split_title("Bad Company - Rock 'n' Roll Fantasy", "The Struts")[1])

    def test_split_title_keeps_dash_inside_brackets(self):
        song, _, _ = split_title("Queen - We Will Rock You (Official Video - Remastered)", "Queen")
        self.assertEqual(song, "We Will Rock You (Official Video - Remastered)")
        self.assertEqual(clean_song_title(song), "We Will Rock You")

    def test_split_title_collaborator_before_song_is_not_the_song(self):
        song, has_prefix, _ = split_title("Brian May - Driven By You (Official Video)", "Queen")
        self.assertFalse(has_prefix)
        self.assertEqual(song, "Driven By You (Official Video)")

    def test_split_title_song_with_uploader_credit_stays_the_song(self):
        song, _, _ = split_title("I'm A Weirdo - Conner4real One-Take Music Video", "Queen")
        self.assertEqual(song, "I'm A Weirdo")

    def test_split_title_song_before_upload_tag_stays_the_song(self):
        song, _, _ = split_title("Driven By You - Official Video", "Queen")
        self.assertEqual(song, "Driven By You")

    def test_clean_song_title_keeps_featuring_and_versions(self):
        self.assertEqual(clean_song_title("Snow (Hey Oh) (Official Music Video) [4K Upgrade]"), "Snow (Hey Oh)")
        self.assertEqual(clean_song_title("Hugs (feat. Pharrell) [HD]"), "Hugs (feat. Pharrell)")
        self.assertEqual(clean_song_title("Brendan's Death Song (Extended)"), "Brendan's Death Song (Extended)")
        self.assertEqual(clean_song_title('Open/Close: "Live"?'), "OpenClose Live")

    def test_song_key_ignores_featuring_punctuation_and_quotes(self):
        self.assertEqual(song_key("Fallin' With Me"), song_key("Fallin’ With Me"))
        self.assertEqual(song_key("Hugs (feat. Pharrell)"), song_key("Hugs"))
        self.assertEqual(song_key("Strange Days feat. Robbie Williams"), song_key("Strange Days"))


class MusicBrainzChannelTests(unittest.TestCase):
    def test_channel_urls_keeps_youtube_channels_only(self):
        relations = [
            {"type": "youtube", "url": {"resource": "https://www.youtube.com/channel/UCfoba7dC3rJrEirb70tS8UA"}},
            {"type": "youtube", "url": {"resource": "https://www.youtube.com/user/thestrutsvevo/"}},
            {"type": "youtube music", "url": {"resource": "https://music.youtube.com/channel/UC6EQ"}},
            {"type": "youtube", "ended": True, "url": {"resource": "https://www.youtube.com/user/oldchannel"}},
            {"type": "social network", "url": {"resource": "https://twitter.com/thestruts"}},
            {"type": "youtube", "url": {"resource": "https://www.youtube.com/@TheStruts?si=x"}},
            {"type": "youtube", "url": {"resource": "https://www.youtube.com/watch?v=abc"}},
        ]
        self.assertEqual(
            channel_urls(relations),
            [
                "https://www.youtube.com/channel/UCfoba7dC3rJrEirb70tS8UA",
                "https://www.youtube.com/user/thestrutsvevo",
                "https://www.youtube.com/@TheStruts",
            ],
        )


if __name__ == "__main__":
    unittest.main()
