#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

import sqlite3
import sys
import tempfile
import threading
import unittest
from contextlib import closing
from pathlib import Path
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from deemix_downloader.indexer_background import BackgroundSearch, SearchWarming
from deemix_downloader.indexer_search import AmbiguousAlbumError


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

    def test_upgrading_search_cache_keeps_pending_work_and_discards_old_results(self):
        for version in (0, 1, 2, 3, 4):
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


if __name__ == "__main__":
    unittest.main()
