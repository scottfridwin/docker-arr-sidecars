#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

import sqlite3
import sys
import tempfile
import threading
import time
import unittest
from contextlib import closing
from pathlib import Path
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from deemix_downloader.deezer_api import DeezerUnavailable
from deemix_downloader.indexer_background import BackgroundSearch, SearchRetryDeferred, SearchWarming
from deemix_downloader.indexer_search import AmbiguousAlbumError
from deemix_downloader.musicbrainz_api import MusicBrainzUnavailable


class BackgroundSearchTests(unittest.TestCase):
    def test_warming_deduplicates_and_returns_completed_results(self):
        entered = threading.Event()
        proceed = threading.Event()
        result = [{"album_id": "1"}]

        def search(**_query):
            entered.set()
            self.assertTrue(proceed.wait(2))
            return result

        with tempfile.TemporaryDirectory() as directory:
            background = BackgroundSearch(directory, Mock(side_effect=search), wait_seconds=0)
            worker = background.start()
            try:
                with self.assertRaises(SearchWarming):
                    background.search(q="artist")
                self.assertTrue(entered.wait(2))
                with self.assertRaises(SearchWarming):
                    background.search(q="artist")
                proceed.set()
                background.wait_seconds = 2
                self.assertEqual(background.search(q="artist"), result)
                self.assertEqual(background.callback.call_count, 1)
            finally:
                proceed.set()
                background.stop()
                worker.join(2)
                self.assertFalse(worker.is_alive())

    def test_slow_search_does_not_block_another_search(self):
        slow_started = threading.Event()
        finish_slow = threading.Event()

        def search(**query):
            if query["q"] == "slow":
                slow_started.set()
                self.assertTrue(finish_slow.wait(2))
            return [{"album_id": query["q"]}]

        with tempfile.TemporaryDirectory() as directory:
            background = BackgroundSearch(directory, search, wait_seconds=0)
            worker = background.start()
            try:
                with self.assertRaises(SearchWarming):
                    background.search(q="slow")
                self.assertTrue(slow_started.wait(2))
                background.wait_seconds = 2
                self.assertEqual(background.search(q="fast"), [{"album_id": "fast"}])
            finally:
                finish_slow.set()
                background.stop()
                worker.join(3)
            self.assertFalse(worker.is_alive())

    def test_warming_dispatches_one_retry_after_completion_without_blocking_searches(self):
        search_started = threading.Event()
        complete_search = threading.Event()
        retry_started = threading.Event()
        complete_retry = threading.Event()

        def search(**query):
            if query["q"] == "slow":
                search_started.set()
                self.assertTrue(complete_search.wait(2))
            return [{"album_id": query["q"]}]

        def retry(results):
            self.assertEqual(results, [{"album_id": "slow"}])
            retry_started.set()
            self.assertTrue(complete_retry.wait(2))

        with tempfile.TemporaryDirectory() as directory:
            on_warmed = Mock(side_effect=retry)
            background = BackgroundSearch(directory, search, wait_seconds=0, on_warmed=on_warmed)
            worker = background.start()
            try:
                with self.assertRaises(SearchWarming):
                    background.search(q="slow")
                self.assertTrue(search_started.wait(2))
                with self.assertRaises(SearchWarming):
                    background.search(q="slow")
                complete_search.set()
                self.assertTrue(retry_started.wait(2))
                background.wait_seconds = 2
                self.assertEqual(background.search(q="another"), [{"album_id": "another"}])
                complete_retry.set()
            finally:
                complete_search.set()
                complete_retry.set()
                background.stop()
                worker.join(3)
            self.assertFalse(worker.is_alive())
            on_warmed.assert_called_once_with([{"album_id": "slow"}])

    def test_deferred_retry_is_rescheduled_without_repeating_the_search(self):
        retried = threading.Event()

        def retry(_results):
            if not retried.is_set():
                retried.set()
                raise SearchRetryDeferred("Lidarr is busy")

        with tempfile.TemporaryDirectory() as directory:
            callback = Mock(return_value=[{"album_id": "1"}])
            on_warmed = Mock(side_effect=retry)
            background = BackgroundSearch(directory, callback, wait_seconds=0, retry_seconds=0.01, on_warmed=on_warmed)
            worker = background.start()
            try:
                with self.assertRaises(SearchWarming):
                    background.search(q="album")
                deadline = time.monotonic() + 2
                while on_warmed.call_count < 2 and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertEqual(on_warmed.call_count, 2)
                callback.assert_called_once_with(q="album")
            finally:
                background.stop()
                worker.join(3)

    def test_interrupted_retry_is_not_dispatched_again_after_restart(self):
        with tempfile.TemporaryDirectory() as directory:
            first = BackgroundSearch(directory, Mock(), wait_seconds=0, on_warmed=Mock())
            with self.assertRaises(SearchWarming):
                first.search(q="album")
            with closing(sqlite3.connect(first.path)) as db, db:
                db.execute("UPDATE searches SET status='completed', result='[]'")
                db.execute("UPDATE search_retries SET status='dispatching'")
            retry = Mock()
            restarted = BackgroundSearch(directory, Mock(), wait_seconds=0, on_warmed=retry)
            worker = restarted.start()
            try:
                self.assertEqual(restarted.search(q="album"), [])
                with closing(sqlite3.connect(restarted.path)) as db:
                    self.assertEqual(db.execute("SELECT status FROM search_retries").fetchone()[0], "uncertain")
                retry.assert_not_called()
            finally:
                restarted.stop()
                worker.join(3)

    def test_pending_retry_survives_restart_and_keeps_old_results_after_dispatch(self):
        with tempfile.TemporaryDirectory() as directory:
            first = BackgroundSearch(directory, Mock(), wait_seconds=0, on_warmed=Mock())
            with self.assertRaises(SearchWarming):
                first.search(q="album")
            with closing(sqlite3.connect(first.path)) as db, db:
                db.execute("UPDATE searches SET status='completed', result='[{\"album_id\":\"1\"}]', updated=0")
            retry = Mock()
            restarted = BackgroundSearch(directory, Mock(), wait_seconds=0, on_warmed=retry)
            worker = restarted.start()
            try:
                deadline = time.monotonic() + 2
                status = None
                while status != "submitted" and time.monotonic() < deadline:
                    with closing(sqlite3.connect(restarted.path)) as db:
                        status = db.execute("SELECT status FROM search_retries").fetchone()[0]
                    time.sleep(0.01)
                self.assertEqual(status, "submitted")
                restarted.prune()
                self.assertEqual(restarted.search(q="album"), [{"album_id": "1"}])
                retry.assert_called_once_with([{"album_id": "1"}])
            finally:
                restarted.stop()
                worker.join(3)

    def test_disabled_retry_drops_pending_requests(self):
        with tempfile.TemporaryDirectory() as directory:
            first = BackgroundSearch(directory, Mock(), wait_seconds=0, on_warmed=Mock())
            with self.assertRaises(SearchWarming):
                first.search(q="album")
            disabled = BackgroundSearch(directory, Mock(), wait_seconds=0)
            with closing(sqlite3.connect(disabled.path)) as db:
                self.assertEqual(db.execute("SELECT COUNT(*) FROM search_retries").fetchone()[0], 0)

    def test_failed_dispatch_is_uncertain_and_not_retried(self):
        with tempfile.TemporaryDirectory() as directory:
            retry = Mock(side_effect=OSError("connection lost"))
            background = BackgroundSearch(
                directory, Mock(return_value=[{"album_id": "1"}]), wait_seconds=0, on_warmed=retry
            )
            worker = background.start()
            try:
                with self.assertRaises(SearchWarming):
                    background.search(q="album")
                deadline = time.monotonic() + 2
                status = None
                while status != "uncertain" and time.monotonic() < deadline:
                    with closing(sqlite3.connect(background.path)) as db:
                        row = db.execute("SELECT status FROM search_retries").fetchone()
                    status = row[0] if row else None
                    time.sleep(0.01)
                self.assertEqual(status, "uncertain")
                background.wait_seconds = 2
                self.assertEqual(background.search(q="album"), [{"album_id": "1"}])
                retry.assert_called_once()
            finally:
                background.stop()
                worker.join(3)

    def test_interrupted_search_is_recovered_after_restart(self):
        with tempfile.TemporaryDirectory() as directory:
            first = BackgroundSearch(directory, Mock(), wait_seconds=0)
            with self.assertRaises(SearchWarming):
                first.search(q="artist")
            with closing(sqlite3.connect(first.path)) as db, db:
                db.execute("UPDATE searches SET status='running'")
            callback = Mock(return_value=[{"album_id": "2"}])
            recovered = BackgroundSearch(directory, callback, wait_seconds=2)
            worker = recovered.start()
            try:
                self.assertEqual(recovered.search(q="artist"), [{"album_id": "2"}])
                callback.assert_called_once_with(q="artist")
            finally:
                recovered.stop()
                worker.join(2)

    def test_periodic_pruning_keeps_pending_and_recent_searches(self):
        with tempfile.TemporaryDirectory() as directory:
            background = BackgroundSearch(directory, Mock(), wait_seconds=0)
            with closing(sqlite3.connect(background.path)) as db, db:
                db.executemany(
                    "INSERT INTO searches VALUES (?, ?, '[]', NULL, ?)",
                    [
                        ('{"q":"old"}', "completed", time.time() - 301),
                        ('{"q":"pending"}', "pending", time.time() - 301),
                        ('{"q":"recent"}', "completed", time.time()),
                    ],
                )
            background.prune()
            with closing(sqlite3.connect(background.path)) as db:
                rows = db.execute("SELECT query FROM searches ORDER BY query").fetchall()
            self.assertEqual(rows, [('{"q":"pending"}',), ('{"q":"recent"}',)])

    def test_upgrading_search_cache_keeps_pending_work_and_discards_old_results(self):
        for version in (0, 1, 2, 3, 4, 5):
            with self.subTest(version=version), tempfile.TemporaryDirectory() as directory:
                first = BackgroundSearch(directory, Mock(), wait_seconds=0)
                with self.assertRaises(SearchWarming):
                    first.search(q="pending")
                with closing(sqlite3.connect(first.path)) as db, db:
                    db.execute(
                        "INSERT INTO searches VALUES (?, 'completed', '[]', NULL, 0)",
                        ('{"q":"stale"}',),
                    )
                    db.execute(f"PRAGMA user_version={version}")
                BackgroundSearch(directory, Mock(), wait_seconds=0)
                with closing(sqlite3.connect(first.path)) as db:
                    rows = db.execute("SELECT query, status FROM searches").fetchall()
                self.assertEqual(rows, [('{"q":"pending"}', "pending")])

    def test_restart_reuses_unexpired_completed_results_but_not_expired_or_failed_results(self):
        with tempfile.TemporaryDirectory() as directory:
            first = BackgroundSearch(directory, Mock(), wait_seconds=0)
            now = time.time()
            with closing(sqlite3.connect(first.path)) as db, db:
                db.executemany(
                    "INSERT INTO searches VALUES (?, ?, ?, NULL, ?)",
                    [
                        ('{"q":"recent"}', "completed", '[{"album_id":"1"}]', now),
                        ('{"q":"expired"}', "completed", "[]", now - 301),
                        ('{"q":"failed"}', "failed", None, now),
                    ],
                )
            callback = Mock()
            restarted = BackgroundSearch(directory, callback, wait_seconds=0)
            self.assertEqual(restarted.search(q="recent"), [{"album_id": "1"}])
            with self.assertRaises(SearchWarming):
                restarted.search(q="expired")
            with self.assertRaises(SearchWarming):
                restarted.search(q="failed")
            callback.assert_not_called()

    def test_errors_are_reported_instead_of_empty_results(self):
        for error in (AmbiguousAlbumError("ambiguous"), RuntimeError("unavailable")):
            with self.subTest(error=error), tempfile.TemporaryDirectory() as directory:
                background = BackgroundSearch(directory, Mock(side_effect=error), wait_seconds=2)
                worker = background.start()
                try:
                    with self.assertRaises(type(error)):
                        background.search(q="artist")
                finally:
                    background.stop()
                    worker.join(2)

    def test_transient_deezer_failure_is_retried_without_caching_partial_results(self):
        with tempfile.TemporaryDirectory() as directory:
            callback = Mock(side_effect=[DeezerUnavailable("temporary"), [{"album_id": "1"}]])
            background = BackgroundSearch(directory, callback, wait_seconds=2, retry_seconds=0.01)
            worker = background.start()
            try:
                self.assertEqual(background.search(q="artist"), [{"album_id": "1"}])
                self.assertEqual(callback.call_count, 2)
            finally:
                background.stop()
                worker.join(2)

    def test_transient_musicbrainz_failure_is_retried_without_caching_partial_results(self):
        with tempfile.TemporaryDirectory() as directory:
            callback = Mock(side_effect=[MusicBrainzUnavailable("temporary"), [{"album_id": "1"}]])
            background = BackgroundSearch(directory, callback, wait_seconds=2, retry_seconds=0.01)
            worker = background.start()
            try:
                self.assertEqual(background.search(q="artist"), [{"album_id": "1"}])
                self.assertEqual(callback.call_count, 2)
            finally:
                background.stop()
                worker.join(2)

    def test_system_exit_does_not_kill_search_worker(self):
        with tempfile.TemporaryDirectory() as directory:
            callback = Mock(side_effect=[SystemExit(1), [{"album_id": "2"}]])
            background = BackgroundSearch(directory, callback, wait_seconds=2)
            worker = background.start()
            try:
                with self.assertRaisesRegex(RuntimeError, "failed"):
                    background.search(q="first")
                self.assertEqual(background.search(q="second"), [{"album_id": "2"}])
                self.assertTrue(worker.is_alive())
            finally:
                background.stop()
                worker.join(2)


if __name__ == "__main__":
    unittest.main()
