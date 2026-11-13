#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

import os
import sys
import tempfile
import threading
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta
from email.utils import format_datetime
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from deemix_downloader import musicbrainz_api


class FakeResponse:
    def __init__(self, status_code, *, headers=None, payload=None):
        self.status_code = status_code
        self.headers = headers or {}
        self.payload = payload

    def json(self):
        return self.payload


class MusicBrainzApiTests(unittest.TestCase):
    def setUp(self):
        self.last_request_patch = patch.object(musicbrainz_api, "_last_request_time", 0.0)
        self.retry_patch = patch.object(musicbrainz_api, "_retry_not_before", 0.0)
        self.interval_patch = patch.object(musicbrainz_api, "_MIN_REQUEST_INTERVAL", 0.0)
        self.last_request_patch.start()
        self.retry_patch.start()
        self.interval_patch.start()
        self.addCleanup(self.interval_patch.stop)
        self.addCleanup(self.retry_patch.stop)
        self.addCleanup(self.last_request_patch.stop)

    def test_retry_after_accepts_seconds_and_http_dates(self):
        self.assertEqual(musicbrainz_api._retry_after_seconds("2"), 2)
        self.assertIsNone(musicbrainz_api._retry_after_seconds("2.5"))

        retry_at = datetime.now(UTC) + timedelta(seconds=30)
        parsed = musicbrainz_api._retry_after_seconds(format_datetime(retry_at, usegmt=True))

        self.assertIsNotNone(parsed)
        self.assertAlmostEqual(parsed, 30, delta=1)

    def test_503_retry_after_is_applied_before_retry(self):
        class FakeSession:
            def __init__(self):
                self.responses = [
                    FakeResponse(503, headers={"Retry-After": "1"}),
                    FakeResponse(200, payload={"release": "ok"}),
                ]

            def get(self, *_args, **_kwargs):
                return self.responses.pop(0)

        with (
            patch.object(musicbrainz_api, "_session", FakeSession()),
            patch.object(musicbrainz_api, "_MIN_REQUEST_INTERVAL", 0.0),
            patch.object(musicbrainz_api.random, "uniform", return_value=0),
            patch.object(musicbrainz_api.time, "sleep") as sleep,
        ):
            result = musicbrainz_api.call_musicbrainz_api("https://musicbrainz.org/test")

        self.assertEqual(result, {"release": "ok"})
        sleep.assert_called_once()
        self.assertAlmostEqual(sleep.call_args.args[0], 5, delta=0.01)

    def test_retry_delay_honors_longer_server_delay_and_adds_jitter(self):
        with patch.object(musicbrainz_api.random, "uniform", return_value=2):
            self.assertEqual(musicbrainz_api._retry_delay(5, 0), 7)
            self.assertEqual(musicbrainz_api._retry_delay(5, 20), 22)

    def test_background_transient_retries_continue_beyond_default_attempt_limit(self):
        class FakeSession:
            def __init__(self):
                self.calls = 0

            def get(self, *_args, **_kwargs):
                self.calls += 1
                return (
                    FakeResponse(503, headers={"Retry-After": "0"})
                    if self.calls <= 11
                    else FakeResponse(200, payload={"ok": True})
                )

        session = FakeSession()
        with (
            patch.object(musicbrainz_api, "_session", session),
            patch.object(musicbrainz_api, "_retry_delay", return_value=0),
            musicbrainz_api.retry_transient_indefinitely(),
        ):
            result = musicbrainz_api.call_musicbrainz_api("url")
        self.assertEqual(result, {"ok": True})
        self.assertEqual(session.calls, 12)

    def test_paged_group_cache_resumes_after_interruption(self):
        with (
            tempfile.TemporaryDirectory() as tmpdir,
            patch.object(musicbrainz_api.cfg, "work_path", Path(tmpdir)),
        ):
            first_page = {"release-count": 101, "releases": [{"id": str(i)} for i in range(100)]}
            last_page = {"release-count": 101, "releases": [{"id": "100", "relations": []}]}
            with patch.object(
                musicbrainz_api,
                "call_musicbrainz_api",
                side_effect=[first_page, musicbrainz_api.MusicBrainzUnavailable("interrupted")],
            ) as call:
                with self.assertRaises(musicbrainz_api.MusicBrainzUnavailable):
                    musicbrainz_api.fetch_musicbrainz_group_releases("group")
                self.assertEqual(call.call_count, 2)
            with patch.object(musicbrainz_api, "call_musicbrainz_api", return_value=last_page) as call:
                releases = musicbrainz_api.fetch_musicbrainz_group_releases("group")
            self.assertEqual(len(releases), 101)
            self.assertEqual(releases["100"]["release-group"]["id"], "group")
            call.assert_called_once()
            self.assertIn("offset=100", call.call_args.args[0])

    def test_expired_group_pages_are_fetched_again(self):
        with (
            tempfile.TemporaryDirectory() as tmpdir,
            patch.object(musicbrainz_api.cfg, "work_path", Path(tmpdir)),
        ):
            page = {"release-count": 1, "releases": [{"id": "1"}]}
            with patch.object(musicbrainz_api, "call_musicbrainz_api", return_value=page):
                musicbrainz_api.fetch_musicbrainz_group_releases("group")
            cache = Path(tmpdir) / "cache" / "mb-release-group-releases-group-0.json"
            expired = time.time() - (musicbrainz_api.cfg.cache_max_age_musicbrainz + 1) * 86400
            os.utime(cache, (expired, expired))
            with patch.object(musicbrainz_api, "call_musicbrainz_api", return_value=page) as call:
                musicbrainz_api.fetch_musicbrainz_group_releases("group")
            call.assert_called_once()

    def test_concurrent_requests_observe_one_shared_rate_limit(self):
        starts = []
        starts_lock = threading.Lock()

        class FakeSession:
            def get(self, *_args, **_kwargs):
                with starts_lock:
                    starts.append(time.monotonic())
                return FakeResponse(200, payload={"ok": True})

        with (
            patch.object(musicbrainz_api, "_session", FakeSession()),
            patch.object(musicbrainz_api, "_MIN_REQUEST_INTERVAL", 0.03),
            ThreadPoolExecutor(max_workers=2) as executor,
        ):
            results = list(executor.map(musicbrainz_api.call_musicbrainz_api, ("url1", "url2")))

        self.assertEqual(results, [{"ok": True}, {"ok": True}])
        self.assertGreaterEqual(abs(starts[1] - starts[0]), 0.025)

    def test_search_budget_aborts_when_retry_after_exceeds_remaining_time(self):
        class FakeSession:
            def get(self, *_args, **_kwargs):
                return FakeResponse(503, headers={"Retry-After": "10"})

        with (
            patch.object(musicbrainz_api, "_session", FakeSession()),
            patch.object(musicbrainz_api, "_MIN_REQUEST_INTERVAL", 0.0),
            musicbrainz_api.request_budget(0.1),
            self.assertRaises(musicbrainz_api.MusicBrainzUnavailable),
        ):
            musicbrainz_api.call_musicbrainz_api("https://musicbrainz.org/test")

    def test_search_budget_aborts_after_slow_successful_request(self):
        class FakeSession:
            def get(self, *_args, **_kwargs):
                time.sleep(0.03)
                return FakeResponse(200, payload={"ok": True})

        with (
            patch.object(musicbrainz_api, "_session", FakeSession()),
            patch.object(musicbrainz_api, "_MIN_REQUEST_INTERVAL", 0.0),
            musicbrainz_api.request_budget(0.01),
            self.assertRaises(musicbrainz_api.MusicBrainzUnavailable),
        ):
            musicbrainz_api.call_musicbrainz_api("https://musicbrainz.org/test")


if __name__ == "__main__":
    unittest.main()
