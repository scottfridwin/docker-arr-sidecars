# SPDX-License-Identifier: GPL-3.0-only
import multiprocessing
import os
import sqlite3
import sys
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
from datetime import date
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from deemix_downloader.quota import (
    DailyDownloadQuota,
    QuotaStateError,
    QuotaTransitionError,
    ReservationResult,
)

ROOT = Path(__file__).resolve().parents[3]
DAY = date(2026, 11, 12)


def _reserve_process(path, job_id, start, results):
    quota = DailyDownloadQuota(path, 3, today=lambda: DAY)
    start.wait()
    results.put(quota.reserve(job_id).value)


def _interrupted_process(path):
    quota = DailyDownloadQuota(path, 1, today=lambda: DAY)
    quota.reserve("interrupted")
    os._exit(0)


class DailyDownloadQuotaTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(dir=ROOT)
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name)
        self.day = DAY

    def quota(self, limit=1):
        return DailyDownloadQuota(self.path, limit, today=lambda: self.day)

    def test_completion_is_durable_and_independent_of_import(self):
        quota = self.quota()
        self.assertEqual(quota.reserve("album"), ReservationResult.RESERVED)
        quota.complete("album")
        # A failed import must not change the already completed download.
        with self.assertRaises(QuotaTransitionError):
            quota.fail("album")
        restarted = self.quota()
        restarted.complete("album")
        self.assertEqual(restarted.reserve("album"), ReservationResult.COMPLETED)
        self.assertEqual(restarted.snapshot().completed, 1)
        self.assertEqual(restarted.reserve("other"), ReservationResult.FULL)

    def test_failure_releases_capacity_and_terminal_ids_are_not_reused(self):
        quota = self.quota()
        self.assertEqual(quota.reserve("first"), ReservationResult.RESERVED)
        quota.fail("first")
        quota.fail("first")
        self.assertEqual(quota.reserve("first"), ReservationResult.FAILED)
        with self.assertRaises(QuotaTransitionError):
            quota.complete("first")
        with self.assertRaises(QuotaTransitionError):
            quota.fail("missing")
        self.assertEqual(quota.reserve("second"), ReservationResult.RESERVED)

    def test_duplicate_grabs_and_unlimited_still_record_downloads(self):
        quota = self.quota(0)
        self.assertEqual(quota.reserve("same"), ReservationResult.RESERVED)
        self.assertEqual(quota.reserve("same"), ReservationResult.RESERVED)
        for i in range(20):
            self.assertEqual(quota.reserve(str(i)), ReservationResult.RESERVED)
            quota.complete(str(i))
        quota.complete("same")
        self.assertEqual(quota.snapshot().completed, 21)
        self.assertFalse(quota.snapshot().full)
        self.assertEqual(self.quota(1).reserve("extra"), ReservationResult.FULL)

    def test_rollover_keeps_unresolved_reservations_and_charges_completion_day(self):
        quota = self.quota(2)
        quota.reserve("done")
        quota.complete("done")
        quota.reserve("pending")
        self.assertTrue(quota.snapshot().full)
        self.day = date(2026, 11, 13)
        self.assertEqual(quota.snapshot().completed, 0)
        self.assertEqual(quota.snapshot().reserved_ids, ("pending",))
        quota.complete("pending")
        quota.complete("pending")
        self.assertEqual(quota.snapshot().completed, 1)
        self.assertEqual(quota.reserve("next"), ReservationResult.RESERVED)
        self.assertEqual(quota.reserve("full"), ReservationResult.FULL)
        self.day = DAY
        self.assertEqual(quota.snapshot().completed, 1)

    def test_restart_after_abrupt_exit_keeps_uncertain_job(self):
        ctx = multiprocessing.get_context("spawn")
        process = ctx.Process(target=_interrupted_process, args=(self.path,))
        process.start()
        process.join(20)
        self.assertEqual(process.exitcode, 0)
        self.day = date(2026, 11, 13)
        quota = self.quota()
        self.assertEqual(quota.snapshot().reserved_ids, ("interrupted",))
        self.assertEqual(quota.reserve("new"), ReservationResult.FULL)
        # Explicit reconciliation with external evidence of successful download.
        quota.complete("interrupted")
        self.assertEqual(self.quota().snapshot().completed, 1)
        self.assertEqual(quota.reserve("new"), ReservationResult.FULL)

    def test_reconcile_known_failure_after_restart(self):
        self.quota().reserve("interrupted")
        quota = self.quota()
        quota.fail("interrupted")
        self.assertEqual(quota.reserve("new"), ReservationResult.RESERVED)

    def test_settling_uncertain_reservation_charges_once_without_changing_terminal_records(self):
        quota = self.quota(0)
        quota.reserve("uncertain")
        quota.reserve("failed")
        quota.fail("failed")
        self.assertIsNone(quota.settle_uncertain("missing"))
        self.assertEqual(quota.settle_uncertain("failed"), ReservationResult.FAILED)
        self.assertEqual(quota.settle_uncertain("uncertain"), ReservationResult.RESERVED)
        self.day = date(2026, 11, 13)
        self.assertEqual(quota.settle_uncertain("uncertain"), ReservationResult.COMPLETED)
        self.assertEqual(quota.snapshot().completed, 0)
        self.day = DAY
        self.assertEqual(quota.snapshot().completed, 1)

    def test_processes_compete_for_capacity_during_initialization(self):
        ctx = multiprocessing.get_context("spawn")
        start = ctx.Event()
        results = ctx.Queue()
        processes = [ctx.Process(target=_reserve_process, args=(self.path, str(i), start, results)) for i in range(12)]
        for process in processes:
            process.start()
        start.set()
        values = [results.get(timeout=30) for _ in processes]
        for process in processes:
            process.join(30)
            self.assertEqual(process.exitcode, 0)
        self.assertEqual(values.count("reserved"), 3, values)
        self.assertEqual(values.count("full"), 9, values)
        self.assertEqual(len(self.quota(3).snapshot().reserved_ids), 3)
        results.close()
        results.join_thread()

    def test_concurrent_duplicate_reservations_count_once(self):
        quota = self.quota()
        with ThreadPoolExecutor(max_workers=12) as executor:
            results = list(executor.map(lambda _: quota.reserve("same"), range(30)))
        self.assertEqual(results, [ReservationResult.RESERVED] * 30)
        self.assertEqual(quota.snapshot().reserved_ids, ("same",))
        with ThreadPoolExecutor(max_workers=12) as executor:
            list(executor.map(lambda _: quota.complete("same"), range(30)))
        self.assertEqual(quota.snapshot().completed, 1)

    def test_migration_of_current_and_old_legacy_state(self):
        legacy = self.path / "daily_download_state"
        legacy.write_text(f"{DAY.isoformat()} 2\n", encoding="utf-8")
        quota = self.quota(3)
        self.assertEqual(quota.snapshot().completed, 2)
        self.assertEqual(quota.reserve("one"), ReservationResult.RESERVED)
        quota.complete("one")
        self.assertEqual(quota.reserve("two"), ReservationResult.FULL)
        self.assertEqual(legacy.read_text(encoding="utf-8"), f"{DAY.isoformat()} 2\n")
        self.day = date(2026, 11, 13)
        self.assertEqual(self.quota(3).snapshot().completed, 0)
        self.day = DAY
        self.assertEqual(self.quota(3).snapshot().completed, 3)

    def test_old_legacy_day_is_validated_even_if_not_today(self):
        (self.path / "daily_download_state").write_text("2025-01-01 7", encoding="utf-8")
        self.assertEqual(self.quota().snapshot().completed, 0)

    def test_corrupt_legacy_fails_closed_even_when_unlimited_or_old(self):
        legacy = self.path / "daily_download_state"
        for value in ("", "garbage", "2020-02-31 2", "2020-01-01 -1", "2020-01-01 2 extra", "2020-01-01 ２"):
            with self.subTest(value=value):
                legacy.write_text(value, encoding="utf-8")
                with self.assertRaises(QuotaStateError):
                    self.quota(0)
        legacy.write_bytes(b"\xff")
        with self.assertRaises(QuotaStateError):
            self.quota()
        self.assertFalse((self.path / "daily_download_quota.sqlite3").exists())

    def test_corrupt_database_and_semantically_invalid_state_fail_closed(self):
        quota = self.quota()
        database = self.path / "daily_download_quota.sqlite3"
        with closing(sqlite3.connect(database)) as connection, connection:
            connection.execute("INSERT INTO jobs VALUES ('bad', 'completed', 'not-a-date')")
        with self.assertRaises(QuotaStateError):
            quota.reserve("another")
        with self.assertRaises(QuotaStateError):
            self.quota()
        database.write_bytes(b"not a database")
        with self.assertRaises(QuotaStateError):
            quota.snapshot()
        with self.assertRaises(QuotaStateError):
            self.quota()

    def test_missing_database_and_incomplete_initialization_fail_closed(self):
        quota = self.quota()
        (self.path / "daily_download_quota.lock").write_text("invalid", encoding="utf-8")
        with self.assertRaises(QuotaStateError):
            quota.reserve("one")
        (self.path / "daily_download_quota.lock").write_text("ready", encoding="utf-8")
        (self.path / "daily_download_quota.sqlite3").unlink()
        with self.assertRaises(QuotaStateError):
            quota.snapshot()
        with self.assertRaises(QuotaStateError):
            self.quota()
        (self.path / "daily_download_quota.lock").write_text("initializing", encoding="utf-8")
        with self.assertRaises(QuotaStateError):
            self.quota()

    def test_schema_tampering_fails_closed(self):
        quota = self.quota()
        with closing(sqlite3.connect(self.path / "daily_download_quota.sqlite3")) as connection, connection:
            connection.execute("DROP TABLE jobs")
            connection.execute("CREATE TABLE jobs (id TEXT, status TEXT NOT NULL, day TEXT)")
        with self.assertRaises(QuotaStateError):
            quota.reserve("one")

    def test_io_errors_fail_closed_and_transactions_roll_back(self):
        quota = self.quota()
        with patch.object(quota, "_connect", side_effect=OSError("unavailable")), self.assertRaises(QuotaStateError):
            quota.reserve("one")
        self.assertEqual(quota.snapshot().reserved_ids, ())
        with patch.object(quota, "_day", side_effect=ValueError("clock failed")), self.assertRaises(QuotaStateError):
            quota.reserve("one")
        self.assertEqual(quota.snapshot().reserved_ids, ())

    def test_invalid_inputs(self):
        for limit in (-1, True, 1.5):
            with self.subTest(limit=limit), self.assertRaises(ValueError):
                self.quota(limit)
        quota = self.quota()
        for job_id in ("", "  ", None):
            with self.subTest(job_id=job_id), self.assertRaises(ValueError):
                quota.reserve(job_id)


if __name__ == "__main__":
    unittest.main()
