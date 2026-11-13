# SPDX-License-Identifier: GPL-3.0-only
"""Persistent, process-safe album download quota; independent of the service.

Create ``DailyDownloadQuota(work_path, limit)`` on a local filesystem shared by
all workers, using the same non-negative limit in every worker. Call
``reserve(job_id)`` immediately before starting an album download. Only
``RESERVED`` authorizes a new download; ``FULL`` is an explicit rejection (the
caller may queue and retry it). IDs are nonempty, globally unique per download
attempt, and must be reused for duplicate requests. A previously reserved ID
returns ``RESERVED`` for idempotency, not permission to start a second worker:
the caller must separately ensure exclusive execution of each job.

Call ``complete`` as soon as the album download succeeds, before import or
post-processing; later import failures must not call ``fail``. Call ``fail``
only when the download is known not to have completed. Both transitions are
idempotent, but a conflicting terminal transition raises ``QuotaTransitionError``.
A retry after failure requires a new job ID. Never reuse IDs, even across days.

The local date of completion determines the charged day. Pending reservations
consume capacity on *every* day until resolved, including after midnight and
restart. ``snapshot`` exposes them for reconciliation; use ``complete`` only
with evidence of success and ``fail`` only with evidence of failure. Unknown
outcomes remain reserved until an operator discards the job, at which point
``settle_uncertain`` charges it conservatively. A limit of zero is unlimited but
jobs and completions are still recorded. State is retained indefinitely.

The legacy ``daily_download_state`` date/count is imported once without changing
that file. Stop the old service before migration: it does not share our locks.
SQLite transactions and an initialization lock require working local filesystem
locking and durable writes; do not delete, restore, or replace state while in
use. Missing initialized state, invalid legacy data, corruption and I/O errors
raise ``QuotaStateError`` rather than resetting the quota. A crash during first
initialization can require operator recovery; do not simply delete the marker.
"""

from __future__ import annotations

import fcntl
import os
import sqlite3
from collections.abc import Callable
from dataclasses import dataclass
from datetime import date
from enum import StrEnum
from pathlib import Path

_SCHEMA = {
    "metadata": "CREATE TABLE metadata (version INTEGER NOT NULL)",
    "legacy": "CREATE TABLE legacy (day TEXT PRIMARY KEY, count INTEGER NOT NULL)",
    "jobs": "CREATE TABLE jobs (id TEXT PRIMARY KEY, status TEXT NOT NULL, day TEXT)",
}


class QuotaStateError(RuntimeError):
    """Persistent quota state is unavailable or cannot be trusted."""


class QuotaTransitionError(ValueError):
    """The requested job transition conflicts with its existing state."""


class ReservationResult(StrEnum):
    """Result of reserving an attempt; terminal results never start a job."""

    RESERVED = "reserved"
    COMPLETED = "completed"
    FAILED = "failed"
    FULL = "full"


@dataclass(frozen=True)
class QuotaSnapshot:
    """Current local-day charges and unresolved IDs, captured atomically."""

    day: date
    completed: int
    reserved_ids: tuple[str, ...]
    limit: int

    @property
    def full(self) -> bool:
        """Whether a new reservation would be rejected at this instant."""
        return self.limit > 0 and self.completed + len(self.reserved_ids) >= self.limit


class DailyDownloadQuota:
    """A durable quota over album-download attempts under ``work_path``.

    ``today`` can be supplied for testing and must return a local calendar
    ``date``; production defaults to ``date.today``. All workers must agree on
    the limit, local timezone and work path. The limit may be changed between
    runs; existing reservations and completions remain accounted for.
    """

    def __init__(self, work_path: str | Path, limit: int, *, today: Callable[[], date] = date.today):
        if isinstance(limit, bool) or not isinstance(limit, int) or limit < 0:
            raise ValueError("limit must be a non-negative integer")
        self.limit = limit
        self._today = today
        self._work = Path(work_path)
        self._db = self._work / "daily_download_quota.sqlite3"
        self._marker = self._work / "daily_download_quota.lock"
        self._legacy = self._work / "daily_download_state"
        self._initialize()

    @staticmethod
    def _parse_day(value: str) -> date:
        parsed = date.fromisoformat(value)
        if parsed.isoformat() != value:
            raise ValueError("noncanonical date")
        return parsed

    def _day(self) -> str:
        value = self._today()
        if type(value) is not date:
            raise ValueError("today must return a date")
        return value.isoformat()

    def _legacy_state(self) -> tuple[str, int] | None:
        try:
            text = self._legacy.read_text(encoding="utf-8")
        except FileNotFoundError:
            return None
        parts = text.split()
        if len(parts) != 2 or not parts[1].isascii() or not parts[1].isdecimal():
            raise ValueError("invalid legacy quota state")
        self._parse_day(parts[0])
        count = int(parts[1])
        if count > 9223372036854775807:
            raise ValueError("legacy count is too large")
        return parts[0], count

    def _connect(self) -> sqlite3.Connection:
        # mode=rw avoids silently creating a new database if state disappears.
        connection = sqlite3.connect(self._db.resolve().as_uri() + "?mode=rw", uri=True, timeout=30)
        try:
            connection.execute("PRAGMA synchronous=FULL")
        except BaseException:
            connection.close()
            raise
        return connection

    def _initialize(self) -> None:
        try:
            self._work.mkdir(parents=True, exist_ok=True)
            with self._marker.open("a+b") as marker:
                fcntl.flock(marker, fcntl.LOCK_EX)
                marker.seek(0)
                state = marker.read()
                if state == b"" and not self._db.exists():
                    legacy = self._legacy_state()
                    marker.write(b"initializing")
                    marker.flush()
                    os.fsync(marker.fileno())
                    self._sync_directory()
                    connection = sqlite3.connect(self._db, timeout=30)
                    try:
                        connection.execute("PRAGMA synchronous=FULL")
                        with connection:
                            connection.execute(_SCHEMA["metadata"])
                            connection.execute("INSERT INTO metadata VALUES (1)")
                            connection.execute(_SCHEMA["legacy"])
                            connection.execute(_SCHEMA["jobs"])
                            if legacy is not None:
                                connection.execute("INSERT INTO legacy VALUES (?, ?)", legacy)
                    finally:
                        connection.close()
                    self._sync_directory()
                    marker.seek(0)
                    marker.truncate()
                    marker.write(b"ready")
                    marker.flush()
                    os.fsync(marker.fileno())
                elif state != b"ready" or not self._db.is_file():
                    raise ValueError("quota initialization marker or database is missing or invalid")
            connection = self._connect()
            try:
                with connection:
                    connection.execute("BEGIN IMMEDIATE")
                    self._validate(connection)
            finally:
                connection.close()
        except (OSError, sqlite3.Error, ValueError, UnicodeError) as exc:
            raise QuotaStateError("cannot initialize trusted quota state") from exc

    def _sync_directory(self) -> None:
        fd = os.open(self._work, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)

    def _validate(self, connection: sqlite3.Connection) -> None:
        if connection.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
            raise ValueError("database integrity check failed")
        schema = connection.execute("SELECT name, sql FROM sqlite_master WHERE type = 'table'").fetchall()
        if dict(schema) != _SCHEMA:
            raise ValueError("invalid quota schema")
        if connection.execute("SELECT version FROM metadata").fetchall() != [(1,)]:
            raise ValueError("invalid quota schema version")
        legacy = connection.execute("SELECT day, count FROM legacy").fetchall()
        if len(legacy) > 1:
            raise ValueError("invalid legacy records")
        for day, count in legacy:
            if not isinstance(day, str) or type(count) is not int or count < 0:
                raise ValueError("invalid legacy record")
            self._parse_day(day)
        for job_id, status, day in connection.execute("SELECT id, status, day FROM jobs"):
            if not isinstance(job_id, str) or not job_id.strip():
                raise ValueError("invalid job ID")
            if status not in ("reserved", "completed", "failed"):
                raise ValueError("invalid job status")
            if status == "completed":
                if not isinstance(day, str):
                    raise ValueError("missing completion day")
                self._parse_day(day)
            elif day is not None:
                raise ValueError("unexpected completion day")

    @staticmethod
    def _check_id(job_id: str) -> None:
        if not isinstance(job_id, str) or not job_id.strip():
            raise ValueError("job_id must be a nonempty string")

    def _run(self, operation):
        try:
            if self._marker.read_bytes() != b"ready":
                raise ValueError("invalid quota initialization marker")
            connection = self._connect()
            try:
                with connection:
                    connection.execute("BEGIN IMMEDIATE")
                    self._validate(connection)
                    return operation(connection)
            finally:
                connection.close()
        except (OSError, sqlite3.Error, UnicodeError) as exc:
            raise QuotaStateError("cannot access trusted quota state") from exc
        except ValueError as exc:
            if isinstance(exc, QuotaTransitionError):
                raise
            raise QuotaStateError("invalid quota state or local date") from exc

    def _snapshot(self, connection: sqlite3.Connection) -> QuotaSnapshot:
        day = self._day()
        legacy = connection.execute("SELECT count FROM legacy WHERE day = ?", (day,)).fetchone()
        completed = connection.execute("SELECT COUNT(*) FROM jobs WHERE status = 'completed' AND day = ?", (day,))
        reserved = connection.execute("SELECT id FROM jobs WHERE status = 'reserved' ORDER BY id")
        return QuotaSnapshot(
            day=self._parse_day(day),
            completed=(legacy[0] if legacy else 0) + completed.fetchone()[0],
            reserved_ids=tuple(row[0] for row in reserved),
            limit=self.limit,
        )

    def snapshot(self) -> QuotaSnapshot:
        """Return today's completion count and all unresolved reservations."""
        return self._run(self._snapshot)

    def reserve(self, job_id: str) -> ReservationResult:
        """Atomically reserve capacity or return an existing/terminal result.

        ``FULL`` creates no record, so the same ID can be retried later.
        """
        self._check_id(job_id)

        def reserve_transaction(connection):
            existing = connection.execute("SELECT status FROM jobs WHERE id = ?", (job_id,)).fetchone()
            if existing:
                return ReservationResult(existing[0])
            if self._snapshot(connection).full:
                return ReservationResult.FULL
            connection.execute("INSERT INTO jobs VALUES (?, 'reserved', NULL)", (job_id,))
            return ReservationResult.RESERVED

        return self._run(reserve_transaction)

    def _finish(self, job_id: str, target: str) -> None:
        self._check_id(job_id)

        def finish_transaction(connection):
            existing = connection.execute("SELECT status FROM jobs WHERE id = ?", (job_id,)).fetchone()
            if not existing or existing[0] not in ("reserved", target):
                raise QuotaTransitionError(f"cannot mark {job_id!r} as {target}")
            if existing[0] == "reserved":
                day = self._day() if target == "completed" else None
                connection.execute("UPDATE jobs SET status = ?, day = ? WHERE id = ?", (target, day, job_id))

        self._run(finish_transaction)

    def complete(self, job_id: str) -> None:
        """Record a known successful download once, irrespective of import."""
        self._finish(job_id, "completed")

    def settle_uncertain(self, job_id: str) -> ReservationResult | None:
        """Charge an unresolved reservation conservatively before discarding its job."""
        self._check_id(job_id)

        def settle_transaction(connection):
            existing = connection.execute("SELECT status FROM jobs WHERE id = ?", (job_id,)).fetchone()
            if not existing:
                return None
            status = ReservationResult(existing[0])
            if status == ReservationResult.RESERVED:
                connection.execute("UPDATE jobs SET status = 'completed', day = ? WHERE id = ?", (self._day(), job_id))
            return status

        return self._run(settle_transaction)

    def fail(self, job_id: str) -> None:
        """Release a reservation only for a download known to have failed."""
        self._finish(job_id, "failed")
