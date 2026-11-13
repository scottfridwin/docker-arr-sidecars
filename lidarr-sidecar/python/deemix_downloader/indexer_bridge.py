#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

"""Authenticated Newznab indexer and NZBGet-compatible Lidarr download bridge."""

from __future__ import annotations

import base64
import binascii
import hashlib
import hmac
import json
import os
import re
import sqlite3
import threading
import time
import xml.etree.ElementTree as ET
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from datetime import UTC, datetime, timedelta
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlsplit

from defusedxml import ElementTree as SafeET
from defusedxml.common import DefusedXmlException

from .download import AUDIO_EXTENSIONS, get_import_path
from .indexer_background import SearchWarming
from .indexer_search import AmbiguousAlbumError
from .logging import log
from .quota import DailyDownloadQuota, QuotaStateError, ReservationResult
from .sqlite_maintenance import compact_if_needed

_NZB_NAMESPACE = "http://www.newzbin.com/DTD/2003/nzb"
_NEWZNAB_NAMESPACE = "http://www.newznab.com/DTD/2010/feeds/attributes/"
_ACTIVE_STATES = ("queued", "waiting_quota", "downloading", "downloaded", "needs_recovery")
_IDEMPOTENT_STATES = (*_ACTIVE_STATES, "completed")
_TERMINAL_STATES = ("completed", "failed", "removed", "needs_recovery")
_MAX_REQUEST_BYTES = 16 * 1024 * 1024


class BridgeRequestError(ValueError):
    """A malformed or unsupported bridge request."""


class BridgeStore:
    """Persistent opaque release identities and NZBGet jobs."""

    def __init__(self, path: str | Path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        try:
            with self._connection() as connection:
                connection.executescript(
                    """
                    CREATE TABLE IF NOT EXISTS releases (
                        token TEXT PRIMARY KEY,
                        target TEXT NOT NULL UNIQUE,
                        payload TEXT NOT NULL
                    );
                    CREATE TABLE IF NOT EXISTS jobs (
                        nzb_id INTEGER PRIMARY KEY AUTOINCREMENT,
                        id TEXT NOT NULL UNIQUE,
                        token TEXT NOT NULL,
                        attempt INTEGER NOT NULL,
                        status TEXT NOT NULL,
                        detail TEXT NOT NULL DEFAULT '',
                        created TEXT NOT NULL,
                        updated TEXT NOT NULL,
                        FOREIGN KEY(token) REFERENCES releases(token)
                    );
                    CREATE TABLE IF NOT EXISTS job_clients (
                        job_id TEXT NOT NULL,
                        client_id TEXT NOT NULL UNIQUE,
                        PRIMARY KEY(job_id, client_id),
                        FOREIGN KEY(job_id) REFERENCES jobs(id)
                    );
                    CREATE TABLE IF NOT EXISTS job_cleanup (
                        job_id TEXT NOT NULL,
                        client_id TEXT NOT NULL,
                        done INTEGER NOT NULL DEFAULT 0,
                        PRIMARY KEY(job_id, client_id),
                        FOREIGN KEY(job_id) REFERENCES jobs(id)
                    );
                    CREATE TABLE IF NOT EXISTS release_activity (
                        token TEXT PRIMARY KEY,
                        updated REAL NOT NULL,
                        FOREIGN KEY(token) REFERENCES releases(token)
                    );
                    CREATE INDEX IF NOT EXISTS jobs_status_nzb_id ON jobs(status, nzb_id);
                    CREATE INDEX IF NOT EXISTS jobs_token_nzb_id ON jobs(token, nzb_id);
                    """
                )
                connection.execute("PRAGMA journal_mode=WAL")
                connection.execute("PRAGMA synchronous=FULL")
                connection.execute(
                    "INSERT OR IGNORE INTO release_activity(token, updated) SELECT token, ? FROM releases",
                    (time.time(),),
                )
                connection.execute(
                    "INSERT OR IGNORE INTO job_cleanup(job_id, client_id) "
                    "SELECT jobs.id, job_clients.client_id FROM jobs JOIN job_clients ON job_clients.job_id=jobs.id "
                    "WHERE jobs.status='completed'"
                )
                connection.execute(
                    "INSERT OR IGNORE INTO job_cleanup(job_id, client_id) "
                    "SELECT jobs.id, jobs.id FROM jobs WHERE jobs.status='completed' "
                    "AND NOT EXISTS (SELECT 1 FROM job_clients WHERE job_clients.job_id=jobs.id)"
                )
        except sqlite3.Error as exc:
            raise RuntimeError("cannot initialize the indexer job database") from exc

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path, timeout=30)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys=ON")
        return connection

    @contextmanager
    def _connection(self) -> Iterator[sqlite3.Connection]:
        connection = self._connect()
        try:
            with connection:
                yield connection
        finally:
            connection.close()

    @contextmanager
    def locked(self) -> Iterator[None]:
        with self._lock:
            yield

    def register_release(self, payload: dict[str, Any]) -> dict[str, Any]:
        if not all(payload.get(key) for key in ("artist_id", "album_id", "release_id", "deezer_album_id")):
            raise ValueError("a release requires Lidarr artist, album, release and Deezer album IDs")
        legacy_target = ":".join(str(payload[key]) for key in ("artist_id", "album_id", "release_id"))
        snapshot = {key: value for key, value in payload.items() if key != "report_title"}
        digest = hashlib.sha256(
            json.dumps(snapshot, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
        ).hexdigest()
        target = f"{legacy_target}:{digest}"
        with self._lock, self._connection() as connection:
            existing = connection.execute("SELECT token, payload FROM releases WHERE target=?", (target,)).fetchone()
            if existing:
                self._touch_release(connection, existing["token"])
                return {"token": existing["token"], **json.loads(existing["payload"])}
            legacy = connection.execute(
                "SELECT token, payload FROM releases WHERE target=?", (legacy_target,)
            ).fetchone()
            if legacy:
                previous = json.loads(legacy["payload"])
                if {key: value for key, value in previous.items() if key != "report_title"} == snapshot:
                    self._touch_release(connection, legacy["token"])
                    return {"token": legacy["token"], **previous}
            token = os.urandom(24).hex()
            connection.execute(
                "INSERT INTO releases(token, target, payload) VALUES (?, ?, ?)",
                (token, target, json.dumps(payload, separators=(",", ":"), ensure_ascii=True)),
            )
            self._touch_release(connection, token)
            return {"token": token, **payload}

    @staticmethod
    def _touch_release(connection: sqlite3.Connection, token: str) -> None:
        connection.execute(
            "INSERT INTO release_activity(token, updated) VALUES (?, ?) "
            "ON CONFLICT(token) DO UPDATE SET updated=excluded.updated",
            (token, time.time()),
        )

    def get_release(self, token: str) -> dict[str, Any] | None:
        with self._lock, self._connection() as connection:
            row = connection.execute("SELECT payload FROM releases WHERE token=?", (token,)).fetchone()
            if row:
                self._touch_release(connection, token)
        return {"token": token, **json.loads(row["payload"])} if row else None

    def submit(self, token: str, client_id: str) -> sqlite3.Row:
        if (
            not client_id
            or len(client_id) > 128
            or not client_id.isascii()
            or not all(char.isalnum() or char in "-_" for char in client_id)
        ):
            raise BridgeRequestError("invalid NZBGet client ID")
        with self._lock, self._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            if not connection.execute("SELECT 1 FROM releases WHERE token=?", (token,)).fetchone():
                raise BridgeRequestError("unknown release identity")
            self._touch_release(connection, token)
            placeholders = ",".join("?" for _ in _IDEMPOTENT_STATES)
            active = connection.execute(
                # All statuses are bound values; only the placeholder count is formatted.
                f"SELECT * FROM jobs WHERE token=? AND status IN ({placeholders}) "  # noqa: S608
                "ORDER BY nzb_id DESC LIMIT 1",
                (token, *_IDEMPOTENT_STATES),
            ).fetchone()
            if active:
                self._add_client_id(connection, active["id"], client_id)
                if active["status"] == "completed":
                    connection.execute(
                        "INSERT OR IGNORE INTO job_cleanup(job_id, client_id) VALUES (?, ?)",
                        (active["id"], client_id),
                    )
                return active
            latest = connection.execute("SELECT MAX(attempt) AS attempt FROM jobs WHERE token=?", (token,)).fetchone()
            attempt = int(latest["attempt"] or 0) + 1
            now = datetime.now(UTC).isoformat()
            job_id = os.urandom(16).hex()
            cursor = connection.execute(
                "INSERT INTO jobs(id, token, attempt, status, created, updated) VALUES (?, ?, ?, 'queued', ?, ?)",
                (job_id, token, attempt, now, now),
            )
            self._add_client_id(connection, job_id, client_id)
            return connection.execute("SELECT * FROM jobs WHERE nzb_id=?", (cursor.lastrowid,)).fetchone()

    @staticmethod
    def _add_client_id(connection: sqlite3.Connection, job_id: str, client_id: str) -> None:
        existing = connection.execute("SELECT job_id FROM job_clients WHERE client_id=?", (client_id,)).fetchone()
        if existing and existing["job_id"] != job_id:
            raise BridgeRequestError("NZBGet client ID is already associated with another job")
        connection.execute("INSERT OR IGNORE INTO job_clients VALUES (?, ?)", (job_id, client_id))

    def client_ids(self, job_id: str) -> tuple[str, ...]:
        with self._lock, self._connection() as connection:
            rows = connection.execute(
                "SELECT client_id FROM job_clients WHERE job_id=? ORDER BY client_id", (job_id,)
            ).fetchall()
        # Older job databases have no external ID mapping; retain their previous identifier.
        return tuple(row["client_id"] for row in rows) or (job_id,)

    def get_job(self, job_id: str) -> sqlite3.Row | None:
        with self._lock, self._connection() as connection:
            return connection.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone()

    def set_job(self, job_id: str, status: str, detail: str = "") -> None:
        now = datetime.now(UTC).isoformat()
        with self._lock, self._connection() as connection:
            cursor = connection.execute(
                "UPDATE jobs SET status=?, detail=?, updated=? WHERE id=?",
                (status, detail[:2000], now, job_id),
            )
            if cursor.rowcount != 1:
                raise RuntimeError("indexer job disappeared during state transition")

    def finish_import(self, job_id: str) -> None:
        with self._lock, self._connection() as connection:
            cursor = connection.execute(
                "UPDATE jobs SET status='completed', detail='', updated=? WHERE id=? AND status='downloaded'",
                (datetime.now(UTC).isoformat(), job_id),
            )
            if cursor.rowcount != 1:
                raise RuntimeError("indexer job disappeared during import completion")
            connection.execute(
                "INSERT OR IGNORE INTO job_cleanup(job_id, client_id) "
                "SELECT job_id, client_id FROM job_clients WHERE job_id=?",
                (job_id,),
            )
            connection.execute(
                "INSERT OR IGNORE INTO job_cleanup(job_id, client_id) "
                "SELECT ?, ? WHERE NOT EXISTS (SELECT 1 FROM job_clients WHERE job_id=?)",
                (job_id, job_id, job_id),
            )

    def pending_cleanup(self) -> dict[str, list[str]]:
        with self._lock, self._connection() as connection:
            rows = connection.execute(
                "SELECT job_id, client_id FROM job_cleanup WHERE done=0 ORDER BY job_id, client_id"
            ).fetchall()
        pending: dict[str, list[str]] = {}
        for row in rows:
            pending.setdefault(row["job_id"], []).append(row["client_id"])
        return pending

    def finish_cleanup(self, job_id: str, client_ids: list[str]) -> None:
        with self._lock, self._connection() as connection:
            connection.executemany(
                "UPDATE job_cleanup SET done=1 WHERE job_id=? AND client_id=?",
                [(job_id, client_id) for client_id in client_ids],
            )

    def removable_jobs(self, cutoff: str) -> list[str]:
        with self._lock, self._connection() as connection:
            rows = connection.execute(
                "SELECT id FROM jobs WHERE status='removed' AND updated < ? "
                "AND NOT EXISTS (SELECT 1 FROM job_cleanup WHERE job_id=jobs.id AND done=0)",
                (cutoff,),
            ).fetchall()
        return [row["id"] for row in rows]

    def prune_jobs_and_releases(self, job_ids: set[str], cutoff: str, release_cutoff: float) -> None:
        with self._lock, self._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            for job_id in job_ids:
                row = connection.execute(
                    "SELECT id FROM jobs WHERE id=? AND status='removed' AND updated < ? "
                    "AND NOT EXISTS (SELECT 1 FROM job_cleanup WHERE job_id=jobs.id AND done=0)",
                    (job_id, cutoff),
                ).fetchone()
                if not row:
                    continue
                connection.execute("DELETE FROM job_cleanup WHERE job_id=?", (job_id,))
                connection.execute("DELETE FROM job_clients WHERE job_id=?", (job_id,))
                connection.execute("DELETE FROM jobs WHERE id=?", (job_id,))
            old_releases = connection.execute(
                "SELECT token FROM release_activity WHERE updated < ? "
                "AND NOT EXISTS (SELECT 1 FROM jobs WHERE jobs.token=release_activity.token)",
                (release_cutoff,),
            ).fetchall()
            for row in old_releases:
                connection.execute("DELETE FROM release_activity WHERE token=?", (row["token"],))
                connection.execute("DELETE FROM releases WHERE token=?", (row["token"],))

    def get_release_for_job(self, job_id: str) -> dict[str, Any]:
        with self._lock, self._connection() as connection:
            row = connection.execute(
                "SELECT releases.token, releases.payload, jobs.attempt FROM releases "
                "JOIN jobs ON jobs.token=releases.token WHERE jobs.id=?",
                (job_id,),
            ).fetchone()
        if not row:
            raise RuntimeError("indexer job has no associated release")
        return {"token": row["token"], "attempt": row["attempt"], **json.loads(row["payload"])}

    def next_job(self) -> sqlite3.Row | None:
        with self._lock, self._connection() as connection:
            return connection.execute(
                "SELECT * FROM jobs WHERE status IN ('queued', 'waiting_quota') ORDER BY nzb_id LIMIT 1"
            ).fetchone()

    def claim_job(self, job_id: str) -> bool:
        with self._lock, self._connection() as connection:
            cursor = connection.execute(
                "UPDATE jobs SET status='downloading', detail='', updated=? "
                "WHERE id=? AND status IN ('queued', 'waiting_quota')",
                (datetime.now(UTC).isoformat(), job_id),
            )
            return cursor.rowcount == 1

    def jobs(self, statuses: tuple[str, ...]) -> list[sqlite3.Row]:
        placeholders = ",".join("?" for _ in statuses)
        with self._lock, self._connection() as connection:
            return connection.execute(
                # All statuses are bound values; only the placeholder count is formatted.
                f"SELECT jobs.*, releases.payload FROM jobs JOIN releases ON jobs.token=releases.token "  # noqa: S608
                f"WHERE jobs.status IN ({placeholders}) ORDER BY jobs.nzb_id",
                statuses,
            ).fetchall()

    def remove_job(self, nzb_id: int, *, allow_recovery: bool = False) -> bool:
        with self._lock, self._connection() as connection:
            cursor = connection.execute(
                "UPDATE jobs SET status='removed', updated=? "
                "WHERE nzb_id=? AND status NOT IN ('downloading', 'downloaded') "
                "AND (status != 'needs_recovery' OR ?)",
                (datetime.now(UTC).isoformat(), nzb_id, allow_recovery),
            )
            return cursor.rowcount == 1

    def get_job_by_nzb_id(self, nzb_id: int) -> sqlite3.Row | None:
        with self._lock, self._connection() as connection:
            return connection.execute("SELECT * FROM jobs WHERE nzb_id=?", (nzb_id,)).fetchone()

    def retry_job(self, nzb_id: int) -> bool:
        with self._lock, self._connection() as connection:
            row = connection.execute("SELECT * FROM jobs WHERE nzb_id=?", (nzb_id,)).fetchone()
            if not row or row["status"] != "failed":
                return False
            attempt = int(row["attempt"]) + 1
            connection.execute(
                "UPDATE jobs SET attempt=?, status='queued', detail='', updated=? WHERE nzb_id=?",
                (attempt, datetime.now(UTC).isoformat(), nzb_id),
            )
            return True

    def recover(self, quota: DailyDownloadQuota) -> None:
        """Stop interrupted jobs for manual reconciliation."""
        for row in self.jobs(("downloading", "downloaded")):
            key = f"{row['id']}:{row['attempt']}"
            if row["status"] == "downloaded":
                try:
                    quota.complete(key)
                except (QuotaStateError, ValueError):
                    self.set_job(
                        row["id"], "needs_recovery", "Download completed but quota state needs operator review"
                    )
                    continue
                self.set_job(
                    row["id"],
                    "needs_recovery",
                    "Download completed before restart; verify/import staged files manually",
                )
                continue
            self.set_job(
                row["id"],
                "needs_recovery",
                "Download was interrupted; verify its outcome and reconcile quota before retrying",
            )


class IndexerBridge:
    """Lidarr indexer and NZBGet protocol service."""

    def __init__(
        self,
        *,
        public_url: str,
        api_key: str,
        client_username: str,
        client_password: str,
        work_path: str | Path,
        import_path: str | Path,
        download_limit: int,
        search: Callable[..., list[dict[str, Any]]],
        download: Callable[[dict[str, Any], Callable[[], None]], bool],
        on_import_complete: Callable[[list[str]], set[str]] | None = None,
        worker_interval: float = 2,
        retention_days: int = 30,
        maintenance: Callable[[], None] | None = None,
        validate_page: Callable[[list[dict], int, int], list[dict]] | None = None,
    ):
        if type(retention_days) is not int or retention_days < 0:
            raise ValueError("indexer retention days must be a non-negative integer")
        parsed_url = urlsplit(public_url)
        if (
            parsed_url.scheme not in ("http", "https")
            or not parsed_url.netloc
            or parsed_url.path not in ("", "/")
            or parsed_url.username
            or parsed_url.password
            or parsed_url.query
            or parsed_url.fragment
            or len(api_key) < 32
            or not client_username
            or len(client_password) < 16
        ):
            raise ValueError("public URL, indexer API key, and download-client credentials are required")
        self.public_url = public_url.rstrip("/")
        self.api_key = api_key
        self.client_username = client_username
        self.client_password = client_password
        self.import_path = str(import_path)
        self.store = BridgeStore(Path(work_path) / "indexer_jobs.sqlite3")
        self.quota = DailyDownloadQuota(work_path, download_limit)
        self.search_callback = search
        self.download_callback = download
        self.on_import_complete = on_import_complete
        self.worker_interval = worker_interval
        self.retention_days = retention_days
        self.maintenance_callback = maintenance
        self.validate_page = validate_page
        self._worker_stop = threading.Event()
        self._removal_lock = threading.Lock()
        self.store.recover(self.quota)

    def start_worker(self) -> threading.Thread:
        thread = threading.Thread(target=self._worker_loop, name="indexer-job-worker", daemon=True)
        thread.start()
        return thread

    def stop_worker(self) -> None:
        self._worker_stop.set()

    def _worker_loop(self) -> None:
        next_cleanup = 0.0
        next_maintenance = 0.0
        while not self._worker_stop.is_set():
            if time.monotonic() >= next_maintenance:
                try:
                    self._maintenance()
                except (OSError, sqlite3.Error, RuntimeError) as exc:
                    log.error(f"Indexer maintenance failed; will retry: {exc}")
                next_maintenance = time.monotonic() + 3600
            if time.monotonic() >= next_cleanup:
                self._retry_cleanup()
                next_cleanup = time.monotonic() + 30
            row = self.store.next_job()
            if row is None or self.store.jobs(("needs_recovery",)):
                self._worker_stop.wait(self.worker_interval)
                continue
            try:
                self._run_job(row)
            except (Exception, SystemExit) as exc:  # noqa: BLE001 - record a visible job failure and keep the worker alive
                log.error(f"Indexer job {row['id']} failed unexpectedly: {exc}")
                current = self.store.get_job(row["id"])
                if current and current["status"] not in _TERMINAL_STATES:
                    self.store.set_job(row["id"], "needs_recovery", f"Unexpected worker error: {exc}")
            self._worker_stop.wait(self.worker_interval)

    def _maintenance(self) -> None:
        if self.maintenance_callback is not None:
            self.maintenance_callback()
        if not self.retention_days:
            return
        cutoff = (datetime.now(UTC) - timedelta(days=self.retention_days)).isoformat()
        history_root = Path(self.import_path) / ".deemix-bridge"
        if history_root.is_symlink():
            raise RuntimeError(f"Unsafe indexer history path: {history_root}")
        candidates = [job_id for job_id in self.store.removable_jobs(cutoff) if re.fullmatch(r"[0-9a-f]{32}", job_id)]
        eligible = self.quota.prune_removed_jobs(candidates, self.retention_days)
        removable = set()
        for job_id in eligible:
            directory = self._history_dest_dir(job_id)
            try:
                directory.rmdir()
            except FileNotFoundError:
                pass
            except OSError as exc:
                log.warning(f"Cannot remove indexer history directory {directory}: {exc}")
                continue
            removable.add(job_id)
        self.store.prune_jobs_and_releases(removable, cutoff, time.time() - self.retention_days * 86400)
        if history_root.is_dir():
            for directory in history_root.iterdir():
                if (
                    not re.fullmatch(r"[0-9a-f]{32}", directory.name)
                    or directory.is_symlink()
                    or not directory.is_dir()
                    or directory.stat().st_mtime >= time.time() - self.retention_days * 86400
                    or self.store.get_job(directory.name) is not None
                ):
                    continue
                try:
                    directory.rmdir()
                except OSError as exc:
                    log.warning(f"Cannot remove orphaned indexer history directory {directory}: {exc}")
        compact_if_needed(self.store.path)
        self.quota.compact()

    def _retry_cleanup(self, job_id: str | None = None) -> None:
        if self.on_import_complete is None:
            return
        pending = {
            pending_job: ids
            for pending_job, ids in self.store.pending_cleanup().items()
            if job_id is None or pending_job == job_id
        }
        client_ids = [client_id for ids in pending.values() for client_id in ids]
        if not client_ids:
            return
        try:
            removed = self.on_import_complete(client_ids)
            if not isinstance(removed, set) or not removed.issubset(client_ids):
                raise RuntimeError("queue cleanup returned invalid download IDs")
            for pending_job, ids in pending.items():
                self.store.finish_cleanup(pending_job, sorted(removed.intersection(ids)))
        except (Exception, SystemExit) as exc:  # noqa: BLE001 - retain cleanup for retry.
            log.error(f"Indexer queue cleanup failed; will retry: {exc}")

    def _run_job(self, row: sqlite3.Row) -> None:
        job_id = row["id"]
        if not self.store.claim_job(job_id):
            return
        release = self.store.get_release_for_job(job_id)
        quota_id = f"{job_id}:{release['attempt']}"
        try:
            reservation = self.quota.reserve(quota_id)
        except (QuotaStateError, ValueError):
            self.store.set_job(job_id, "needs_recovery", "Quota reservation failed; operator review required")
            raise
        if reservation == ReservationResult.FULL:
            self.store.set_job(job_id, "waiting_quota", "Waiting for the local calendar day quota to reset")
            return
        if reservation in (ReservationResult.COMPLETED, ReservationResult.FAILED):
            self.store.set_job(
                job_id,
                "needs_recovery",
                f"Quota job is already {reservation.value}; refusing a duplicate download",
            )
            return

        try:
            release["lidarr_download_ids"] = list(self.store.client_ids(job_id))
            release["bridge_job_id"] = job_id
        except (sqlite3.Error, RuntimeError):
            self.quota.fail(quota_id)
            raise
        download_completed = False
        completion_started = False

        def mark_download_complete() -> None:
            nonlocal completion_started, download_completed
            completion_started = True
            self.store.set_job(job_id, "downloaded", "Download complete; forced Lidarr import is in progress")
            self.quota.complete(quota_id)
            download_completed = True

        try:
            imported = self.download_callback(release, mark_download_complete)
        except (Exception, SystemExit):
            detail = (
                "Download finished; inspect quota and import state"
                if completion_started
                else "Download outcome is unknown; inspect quota and staged files"
            )
            self.store.set_job(job_id, "needs_recovery", detail)
            raise
        if imported and not download_completed:
            self.store.set_job(job_id, "needs_recovery", "Import reported success without recorded download completion")
            raise RuntimeError("download worker reported import success without recording download completion")
        if not download_completed:
            self.quota.fail(quota_id)
        current = self.store.get_job(job_id)
        if current and current["status"] == "removed":
            return
        if imported:
            self._history_dest_dir(job_id).mkdir(parents=True, exist_ok=True)
            self.store.finish_import(job_id)
            self._retry_cleanup(job_id)
        elif download_completed:
            self.store.set_job(job_id, "needs_recovery", "Download finished; strict manual import needs review")
        else:
            self.store.set_job(job_id, "failed", "Download failed")

    def _history_dest_dir(self, job_id: str) -> Path:
        return Path(self.import_path) / ".deemix-bridge" / job_id

    def _release_import_path(self, release: dict[str, Any]) -> Path:
        return get_import_path(
            release["artist_name"],
            release["album_title"],
            release.get("year", ""),
            release.get("album_foreign_id", ""),
            import_root=Path(self.import_path),
        )

    def _remove_recovery_audio(self, job_id: str) -> None:
        folder = self._release_import_path(self.store.get_release_for_job(job_id))
        root = Path(self.import_path).resolve()
        if folder.parent.resolve() != root or folder.is_symlink():
            raise RuntimeError(f"Unsafe recovery import path: {folder}")
        marker = folder / f".deemix-owner-{job_id}"
        if marker.is_symlink() or not marker.is_file():
            log.warning(f"Keeping recovery audio in {folder}: job ownership is not recorded")
            return
        for row in self.store.jobs((*_ACTIVE_STATES, "completed")):
            if row["id"] != job_id and self._release_import_path(json.loads(row["payload"])) == folder:
                log.warning(f"Keeping recovery audio in {folder}: another job uses the same folder")
                marker.unlink()
                return
        removed = 0
        for path in folder.iterdir():
            if not path.is_symlink() and path.is_file() and path.suffix.lower() in AUDIO_EXTENSIONS:
                path.unlink()
                removed += 1
        marker.unlink()
        if removed:
            log.info(f"Removed {removed} recovery audio file(s) from {folder}")
        if not any(folder.iterdir()):
            folder.rmdir()

    def _remove_job(self, nzb_id: int) -> bool:
        with self._removal_lock, self.store.locked():
            job = self.store.get_job_by_nzb_id(nzb_id)
            if job and job["status"] == "needs_recovery":
                quota_id = f"{job['id']}:{job['attempt']}"
                quota_status = self.quota.settle_uncertain(quota_id)
                if quota_status == ReservationResult.RESERVED:
                    log.warning(
                        f"Charged uncertain download {job['id']} to today's quota before removing it; "
                        "review any staged or partially imported files before retrying"
                    )
                else:
                    log.warning(f"Removing recovery job {job['id']}; review staged or partially imported files")
                self._remove_recovery_audio(job["id"])
                return self.store.remove_job(nzb_id, allow_recovery=True)
            return self.store.remove_job(nzb_id)

    def _authenticated(self, query: dict[str, list[str]]) -> bool:
        supplied = query.get("apikey", [""])[0]
        return hmac.compare_digest(supplied, self.api_key)

    def _search_results(self, query: dict[str, list[str]]) -> list[dict[str, Any]]:
        request_type = query.get("t", [""])[0]
        artist = query.get("artist", [""])[0]
        album = query.get("album", [""])[0]
        q = query.get("q", [""])[0]
        year_value = query.get("year", [""])[0]
        offset_value = query.get("offset", ["0"])[0]
        limit_value = query.get("limit", ["100"])[0]
        if year_value and (not year_value.isascii() or not year_value.isdecimal() or len(year_value) != 4):
            raise BridgeRequestError("year must be a four-digit year")
        year = int(year_value) if year_value else None
        if request_type not in ("music", "search"):
            raise BridgeRequestError("only music and search requests are supported")
        if request_type == "music" and not artist:
            raise BridgeRequestError("music search requires an artist")
        if request_type == "music" and not (album or q):
            return []
        if request_type == "search" and not (q or artist or album):
            return []
        if any(not value.isascii() or not value.isdecimal() or len(value) > 9 for value in (offset_value, limit_value)):
            raise BridgeRequestError("offset and limit must be non-negative integers")
        offset, limit = int(offset_value), int(limit_value)
        if not 1 <= limit <= 100:
            raise BridgeRequestError("limit must be between 1 and 100")
        results = self.search_callback(artist=artist, album=album, q=q, year=year, request_type=request_type)
        if self.validate_page is not None:
            return self.validate_page(results, offset, limit)
        return results[offset : offset + limit]

    def _rss(self, results: list[dict[str, Any]]) -> bytes:
        rss = ET.Element("rss", {"version": "2.0", "xmlns:newznab": _NEWZNAB_NAMESPACE})
        channel = ET.SubElement(rss, "channel")
        for tag, text in (
            ("title", "Lidarr Deemix Indexer"),
            ("link", self.public_url + "/api"),
            ("description", "Verified Deezer releases matched to Lidarr albums"),
            ("language", "en-us"),
        ):
            ET.SubElement(channel, tag).text = text
        for result in results:
            release = self.store.register_release(result)
            token = release["token"]
            query = f"apikey={self.api_key}&t=get&id={token}"
            link = f"{self.public_url}/api?{query}"
            item = ET.SubElement(channel, "item")
            ET.SubElement(item, "title").text = result["report_title"]
            guid = ET.SubElement(item, "guid", {"isPermaLink": "false"})
            guid.text = token
            ET.SubElement(item, "link").text = link
            ET.SubElement(item, "pubDate").text = datetime.now(UTC).strftime("%a, %d %b %Y %H:%M:%S GMT")
            ET.SubElement(item, "category").text = "Audio"
            ET.SubElement(item, "description").text = "Verified Deezer match; quality is determined by the download"
            ET.SubElement(item, "enclosure", {"url": link, "length": "0", "type": "application/x-nzb"})
            attributes = ET.SubElement(item, f"{{{_NEWZNAB_NAMESPACE}}}attr")
            attributes.set("name", "category")
            attributes.set("value", "3000")
            ET.SubElement(item, f"{{{_NEWZNAB_NAMESPACE}}}attr", {"name": "size", "value": "0"})
        return ET.tostring(rss, encoding="utf-8", xml_declaration=True)

    def _capabilities(self) -> bytes:
        root = ET.Element("caps")
        ET.SubElement(root, "server", {"version": "1.0", "title": "Lidarr Deemix Indexer"})
        ET.SubElement(root, "limits", {"max": "100", "default": "100"})
        searching = ET.SubElement(root, "searching")
        ET.SubElement(searching, "search", {"available": "yes", "supportedParams": "q", "searchEngine": "raw"})
        ET.SubElement(searching, "musicSearch", {"available": "yes", "supportedParams": "q,artist,album"})
        categories = ET.SubElement(root, "categories")
        audio = ET.SubElement(categories, "category", {"id": "3000", "name": "Audio"})
        for category_id, name in ((3010, "MP3"), (3030, "Podcast"), (3040, "Lossless")):
            ET.SubElement(audio, "subcat", {"id": str(category_id), "name": name})
        return ET.tostring(root, encoding="utf-8", xml_declaration=True)

    def _nzb(self, token: str) -> bytes | None:
        if not self.store.get_release(token):
            return None
        root = ET.Element(f"{{{_NZB_NAMESPACE}}}nzb")
        head = ET.SubElement(root, f"{{{_NZB_NAMESPACE}}}head")
        ET.SubElement(head, f"{{{_NZB_NAMESPACE}}}meta", {"type": "name"}).text = f"{token}.nzb"
        ET.SubElement(head, f"{{{_NZB_NAMESPACE}}}meta", {"type": "deemix-release-id"}).text = token
        file_element = ET.SubElement(
            root,
            f"{{{_NZB_NAMESPACE}}}file",
            {"poster": "Lidarr Deemix Indexer", "date": str(int(time.time())), "subject": f'"{token}.flac"'},
        )
        groups = ET.SubElement(file_element, f"{{{_NZB_NAMESPACE}}}groups")
        ET.SubElement(groups, f"{{{_NZB_NAMESPACE}}}group").text = "alt.binaries.music"
        segments = ET.SubElement(file_element, f"{{{_NZB_NAMESPACE}}}segments")
        ET.SubElement(segments, f"{{{_NZB_NAMESPACE}}}segment", {"bytes": "1", "number": "1"}).text = "1"
        return ET.tostring(root, encoding="utf-8", xml_declaration=True)

    def _basic_authenticated(self, header: str) -> bool:
        if not header.startswith("Basic "):
            return False
        try:
            decoded = base64.b64decode(header[6:], validate=True).decode("utf-8")
        except (binascii.Error, UnicodeDecodeError):
            return False
        username, separator, password = decoded.partition(":")
        return bool(
            separator
            and hmac.compare_digest(username, self.client_username)
            and hmac.compare_digest(password, self.client_password)
        )

    def _jsonrpc(self, request: dict[str, Any]) -> tuple[Any, dict[str, Any] | None]:
        if request.get("jsonrpc") != "2.0" or not isinstance(request.get("method"), str):
            return None, {"code": -32600, "message": "Invalid Request"}
        method = request["method"]
        params = request.get("params", [])
        if not isinstance(params, list):
            return None, {"code": -32602, "message": "Invalid params"}
        if method == "version":
            return "21.0", None
        if method == "status":
            return {"DownloadPaused": False, "DownloadRate": 0}, None
        if method == "config":
            settings = {
                "MainDir": self.import_path,
                "DestDir": self.import_path,
                "AppendCategoryDir": "no",
                "Category1.Name": "Music",
                "Category1.DestDir": self.import_path,
                "Category1.Unpack": "no",
                "Category1.DefScript": "",
                "Category1.Aliases": "",
            }
            return [{"Name": name, "Value": value} for name, value in settings.items()], None
        if method == "append":
            if len(params) < 3 or not isinstance(params[0], str) or not isinstance(params[1], str):
                return None, {"code": -32602, "message": "append requires a title and NZB payload"}
            if params[2] != "Music" or (len(params) > 5 and params[5] is True):
                return 0, None
            try:
                nzb_bytes = base64.b64decode(params[1], validate=True)
                root = SafeET.fromstring(nzb_bytes, forbid_dtd=True)
            except (binascii.Error, ET.ParseError, DefusedXmlException, ValueError):
                return None, {"code": -32602, "message": "invalid NZB payload"}
            token = next(
                (
                    element.text
                    for element in root.findall(f".//{{{_NZB_NAMESPACE}}}meta")
                    if element.attrib.get("type") == "deemix-release-id"
                ),
                None,
            )
            if not isinstance(token, str) or not self.store.get_release(token):
                return None, {"code": -32602, "message": "NZB has no valid release identity"}
            if len(params) <= 9:
                return None, {"code": -32602, "message": "missing NZBGet client ID parameter"}
            client_parameter = params[9]
            if (
                not isinstance(client_parameter, list)
                or len(client_parameter) != 2
                or client_parameter[0] != "drone"
                or not isinstance(client_parameter[1], str)
            ):
                return None, {"code": -32602, "message": "invalid NZBGet client ID parameter"}
            client_id = client_parameter[1]
            try:
                job = self.store.submit(token, client_id)
            except BridgeRequestError as exc:
                return None, {"code": -32602, "message": str(exc)}
            return int(job["nzb_id"]), None
        if method == "listgroups":
            rows = self.store.jobs(_ACTIVE_STATES)
            groups = []
            for row in rows:
                payload = json.loads(row["payload"])
                title = payload["artist_name"] + " - " + payload["album_title"]
                if row["status"] == "waiting_quota":
                    title += " [waiting for daily download quota]"
                elif row["status"] == "needs_recovery":
                    title += " [needs manual recovery]"
                elif row["status"] == "downloaded":
                    title += " [manual import in progress]"
                for client_id in self.store.client_ids(row["id"]):
                    groups.append(
                        {
                            "NzbId": row["nzb_id"],
                            "NzbName": title,
                            "Category": "Music",
                            "FileSizeHi": 0,
                            "FileSizeLo": 1,
                            "PausedSizeHi": 0,
                            "PausedSizeLo": 0,
                            "RemainingSizeHi": 0,
                            "RemainingSizeLo": 1,
                            "ActiveDownloads": int(row["status"] in ("downloading", "downloaded")),
                            "Parameters": [{"Name": "drone", "Value": client_id}],
                        }
                    )
            return groups, None
        if method == "history":
            rows = self.store.jobs(("completed", "failed"))
            history = []
            for row in rows:
                payload = json.loads(row["payload"])
                succeeded = row["status"] == "completed"
                dest_dir = self._history_dest_dir(row["id"])
                dest_dir.mkdir(parents=True, exist_ok=True)
                for client_id in self.store.client_ids(row["id"]):
                    history.append(
                        {
                            "Id": row["nzb_id"],
                            "Name": payload["artist_name"] + " - " + payload["album_title"],
                            "Category": "Music",
                            "Parameters": [{"Name": "drone", "Value": client_id}],
                            "DestDir": str(dest_dir),
                            "FinalDir": "",
                            "FileSizeHi": 0,
                            "FileSizeLo": 1,
                            "ParStatus": "SUCCESS" if succeeded else "FAILURE",
                            "UnpackStatus": "SUCCESS" if succeeded else "NONE",
                            "MoveStatus": "SUCCESS" if succeeded else "NONE",
                            "ScriptStatus": "SUCCESS" if succeeded else "NONE",
                            "DeleteStatus": "SUCCESS" if succeeded else "NONE",
                            "MarkStatus": "GOOD" if succeeded else "BAD",
                        }
                    )
            return history, None
        if method == "editqueue":
            if len(params) < 4:
                return False, None
            command, nzb_id = params[0], params[3]
            try:
                nzb_id = int(nzb_id)
            except (TypeError, ValueError):
                return False, None
            if command == "GroupFinalDelete":
                return self._remove_job(nzb_id), None
            if command == "HistoryDelete":
                return self._remove_job(nzb_id), None
            if command == "HistoryRedownload":
                return self.store.retry_job(nzb_id), None
            return False, None
        return None, {"code": -32601, "message": "Method not found"}

    def handler(self) -> type[BaseHTTPRequestHandler]:
        bridge = self

        class Handler(BaseHTTPRequestHandler):
            server_version = "LidarrDeemixBridge/1.0"
            sys_version = ""

            def log_message(self, _format: str, *_args: Any) -> None:
                return

            def _respond(self, status: HTTPStatus, body: bytes, content_type: str) -> None:
                try:
                    self.send_response(status)
                    self.send_header("Content-Type", content_type)
                    self.send_header("Content-Length", str(len(body)))
                    self.send_header("Cache-Control", "no-store")
                    self.end_headers()
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    log.debug("Indexer client disconnected before the response was written")

            def _error(self, status: HTTPStatus, message: str) -> None:
                root = ET.Element("error", {"code": str(int(status)), "description": message[:300]})
                self._respond(status, ET.tostring(root, encoding="utf-8", xml_declaration=True), "application/xml")

            def do_GET(self) -> None:
                parsed = urlsplit(self.path)
                try:
                    query = parse_qs(parsed.query, keep_blank_values=True, max_num_fields=40)
                except ValueError:
                    self._error(HTTPStatus.BAD_REQUEST, "Too many query parameters")
                    return
                if parsed.path != "/api" or not bridge._authenticated(query):
                    self._error(HTTPStatus.UNAUTHORIZED, "Invalid API key")
                    return
                request_type = query.get("t", [""])[0]
                if request_type == "caps":
                    self._respond(HTTPStatus.OK, bridge._capabilities(), "application/xml; charset=utf-8")
                    return
                if request_type == "get":
                    token = query.get("id", [""])[0]
                    nzb = bridge._nzb(token)
                    if nzb is None:
                        self._error(HTTPStatus.NOT_FOUND, "Unknown release")
                    else:
                        self._respond(HTTPStatus.OK, nzb, "application/x-nzb")
                    return
                try:
                    results = bridge._search_results(query)
                    self._respond(HTTPStatus.OK, bridge._rss(results), "application/rss+xml; charset=utf-8")
                except BridgeRequestError as exc:
                    self._error(HTTPStatus.BAD_REQUEST, str(exc))
                except SearchWarming as exc:
                    self._error(HTTPStatus.SERVICE_UNAVAILABLE, str(exc))
                except (OSError, RuntimeError, sqlite3.Error) as exc:
                    log.error(f"Indexer search unavailable: {exc}")
                    self._error(HTTPStatus.SERVICE_UNAVAILABLE, "Search upstream is unavailable")
                except AmbiguousAlbumError as exc:
                    self._error(HTTPStatus.BAD_REQUEST, str(exc))

            def do_POST(self) -> None:
                if urlsplit(self.path).path != "/jsonrpc" or not bridge._basic_authenticated(
                    self.headers.get("Authorization", "")
                ):
                    self._respond(HTTPStatus.UNAUTHORIZED, b"", "application/json")
                    return
                try:
                    length = int(self.headers.get("Content-Length", "0"))
                except ValueError:
                    self._respond(HTTPStatus.BAD_REQUEST, b"", "application/json")
                    return
                if not 0 < length <= _MAX_REQUEST_BYTES:
                    self._respond(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, b"", "application/json")
                    return
                try:
                    request = json.loads(self.rfile.read(length))
                except (json.JSONDecodeError, UnicodeDecodeError):
                    self._respond(HTTPStatus.BAD_REQUEST, b"", "application/json")
                    return
                if not isinstance(request, dict):
                    self._respond(HTTPStatus.BAD_REQUEST, b"", "application/json")
                    return
                try:
                    result, error = bridge._jsonrpc(request)
                except (OSError, RuntimeError, sqlite3.Error) as exc:
                    log.error(f"NZBGet request failed: {exc}")
                    result, error = None, {"code": -32000, "message": "Bridge state is unavailable"}
                response = {"jsonrpc": "2.0", "id": request.get("id")}
                if error:
                    response["error"] = error
                else:
                    response["result"] = result
                body = json.dumps(response, separators=(",", ":")).encode("utf-8")
                self._respond(HTTPStatus.OK, body, "application/json")

        return Handler

    def serve(
        self,
        host: str,
        port: int,
        on_listening: Callable[[int], None] | None = None,
        monitored_worker: threading.Thread | None = None,
    ) -> None:
        server = ThreadingHTTPServer((host, port), self.handler())
        server.daemon_threads = True
        log.info(f"Newznab/NZBGet bridge listening on {host}:{port}")
        server_thread = threading.Thread(
            target=server.serve_forever, kwargs={"poll_interval": 0.5}, name="indexer-http", daemon=True
        )
        server_thread.start()
        worker = None
        try:
            if on_listening is not None:
                on_listening(server.server_port)
            worker = self.start_worker()
            while (
                server_thread.is_alive()
                and worker.is_alive()
                and (monitored_worker is None or monitored_worker.is_alive())
            ):
                worker.join(timeout=1)
            raise RuntimeError("Indexer HTTP server or background worker stopped unexpectedly")
        finally:
            server.shutdown()
            server_thread.join()
            self.stop_worker()
            if worker is not None:
                worker.join(timeout=10)
            server.server_close()


def build_bridge_from_environment(
    search: Callable[..., list[dict[str, Any]]],
    download: Callable[[dict[str, Any], Callable[[], None]], bool],
    on_import_complete: Callable[[list[str]], set[str]] | None = None,
    maintenance: Callable[[], None] | None = None,
    validate_page: Callable[[list[dict], int, int], list[dict]] | None = None,
) -> IndexerBridge:
    """Build the bridge from required, explicit deployment settings."""
    api_key = os.environ.get("AUDIO_INDEXER_API_KEY", "")
    public_url = os.environ.get("AUDIO_INDEXER_PUBLIC_URL", "")
    client_username = os.environ.get("AUDIO_INDEXER_CLIENT_USERNAME", "lidarr-sidecar")
    client_password = os.environ.get("AUDIO_INDEXER_CLIENT_PASSWORD", "")
    if not client_password:
        raise ValueError("AUDIO_INDEXER_CLIENT_PASSWORD must be configured")
    # Lidarr must reach the bridge over its private container network.
    host = os.environ.get("AUDIO_INDEXER_BIND", "0.0.0.0")  # noqa: S104
    port = int(os.environ.get("AUDIO_INDEXER_PORT", "9797"))
    if not 1 <= port <= 65535:
        raise ValueError("AUDIO_INDEXER_PORT must be between 1 and 65535")
    bridge = IndexerBridge(
        public_url=public_url,
        api_key=api_key,
        client_username=client_username,
        client_password=client_password,
        work_path=os.environ.get("AUDIO_WORK_PATH", "/work"),
        import_path=os.environ.get("AUDIO_SHARED_LIDARR_PATH", "/sidecar-import"),
        download_limit=int(os.environ.get("AUDIO_DAILY_DOWNLOAD_LIMIT", "0")),
        search=search,
        download=download,
        on_import_complete=on_import_complete,
        retention_days=int(os.environ.get("AUDIO_INDEXER_RETENTION_DAYS", "30")),
        maintenance=maintenance,
        validate_page=validate_page,
    )
    bridge.bind_host = host
    bridge.bind_port = port
    return bridge
