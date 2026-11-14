#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

"""Persistent, deduplicated background searches for the Newznab bridge."""

from __future__ import annotations

import json
import sqlite3
import threading
import time
from collections.abc import Callable
from contextlib import closing
from pathlib import Path
from typing import Any

from .deezer_api import DeezerUnavailable
from .indexer_search import AmbiguousAlbumError
from .logging import log
from .musicbrainz_api import MusicBrainzUnavailable
from .sqlite_maintenance import compact_if_needed


class SearchWarming(RuntimeError):
    """Search metadata is still being collected."""


class SearchRetryDeferred(RuntimeError):
    """The search retry is safe to attempt later; no command was sent."""


class SearchRetryRejected(RuntimeError):
    """The search retry cannot be sent; no command was sent."""


class BackgroundSearch:
    def __init__(
        self,
        work_path: str | Path,
        search: Callable[..., list[dict[str, Any]]],
        *,
        wait_seconds: float = 10.0,
        retry_seconds: float = 30.0,
        on_warmed: Callable[[list[dict[str, Any]]], None] | None = None,
    ):
        self.path = Path(work_path) / "indexer_searches.sqlite3"
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.callback = search
        self.wait_seconds = wait_seconds
        self.retry_seconds = retry_seconds
        self.on_warmed = on_warmed
        self.condition = threading.Condition()
        self.stopping = False
        self.worker: threading.Thread | None = None
        with closing(self._connect()) as db, db:
            db.execute(
                "CREATE TABLE IF NOT EXISTS searches ("
                "query TEXT PRIMARY KEY, status TEXT NOT NULL, result TEXT, error TEXT, updated REAL NOT NULL)"
            )
            db.execute(
                "CREATE TABLE IF NOT EXISTS search_retries ("
                "query TEXT PRIMARY KEY, status TEXT NOT NULL, error TEXT, retry_after REAL NOT NULL DEFAULT 0)"
            )
            version = db.execute("PRAGMA user_version").fetchone()[0]
            if version in (0, 1, 2, 3, 4, 5):
                db.execute("DELETE FROM searches WHERE status IN ('completed', 'failed', 'ambiguous')")
                db.execute("PRAGMA user_version=6")
            elif version == 6:
                db.execute("DELETE FROM searches WHERE status IN ('failed', 'ambiguous')")
            else:
                raise RuntimeError(f"Unsupported indexer search database version: {version}")
            db.execute("UPDATE searches SET status='pending' WHERE status='running'")
            db.execute("DELETE FROM search_retries WHERE query NOT IN (SELECT query FROM searches)")
            interrupted = db.execute(
                "UPDATE search_retries SET status='uncertain', error='Interrupted while sending Lidarr command' "
                "WHERE status='dispatching'"
            ).rowcount
            if interrupted:
                log.error(
                    f"{interrupted} automatic search retry outcome(s) are uncertain; inspect Lidarr before retrying"
                )
            if self.on_warmed is None:
                cancelled = db.execute("DELETE FROM search_retries WHERE status='pending'").rowcount
                if cancelled:
                    log.warning(f"Cancelled {cancelled} pending automatic search retry request(s): feature disabled")

    def _connect(self) -> sqlite3.Connection:
        db = sqlite3.connect(self.path, timeout=30)
        db.row_factory = sqlite3.Row
        return db

    def start(self) -> threading.Thread:
        worker = threading.Thread(target=self._supervise, name="indexer-search-supervisor", daemon=True)
        self.worker = worker
        worker.start()
        return worker

    def _supervise(self) -> None:
        workers = [
            threading.Thread(target=self._run, name=f"indexer-search-worker-{number}", daemon=True)
            for number in range(1, 3)
        ]
        if self.on_warmed is not None:
            workers.append(threading.Thread(target=self._run_retries, name="indexer-search-retry", daemon=True))
        for worker in workers:
            worker.start()
        while not self.stopping and all(worker.is_alive() for worker in workers):
            workers[0].join(timeout=0.1)
        if not self.stopping:
            log.error("Indexer search worker stopped unexpectedly")
            with self.condition:
                self.stopping = True
                self.condition.notify_all()
        for worker in workers:
            worker.join(timeout=1)

    def stop(self) -> None:
        with self.condition:
            self.stopping = True
            self.condition.notify_all()

    def prune(self) -> None:
        with self.condition, closing(self._connect()) as db, db:
            self._prune_searches(db)
        compact_if_needed(self.path)

    @staticmethod
    def _prune_searches(db: sqlite3.Connection) -> None:
        db.execute(
            "DELETE FROM searches WHERE status IN ('completed', 'failed', 'ambiguous') AND updated < ? "
            "AND NOT EXISTS (SELECT 1 FROM search_retries WHERE search_retries.query=searches.query "
            "AND search_retries.status IN ('pending', 'dispatching'))",
            (time.time() - 300,),
        )
        db.execute("DELETE FROM search_retries WHERE query NOT IN (SELECT query FROM searches)")

    def search(self, **query: Any) -> list[dict[str, Any]]:
        key = json.dumps(query, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
        deadline = time.monotonic() + self.wait_seconds
        with self.condition:
            with closing(self._connect()) as db, db:
                self._prune_searches(db)
                row = db.execute("SELECT * FROM searches WHERE query=?", (key,)).fetchone()
                if row is None:
                    count = db.execute(
                        "SELECT COUNT(*) FROM searches WHERE status IN ('pending', 'running')"
                    ).fetchone()
                    if count[0] >= 1000:
                        raise RuntimeError("Indexer search queue is full")
                    db.execute(
                        "INSERT INTO searches(query, status, updated) VALUES (?, 'pending', ?)", (key, time.time())
                    )
                    log.info(f"Queued background indexer search: {key}")
                    self.condition.notify_all()
            while True:
                with closing(self._connect()) as db:
                    row = db.execute("SELECT * FROM searches WHERE query=?", (key,)).fetchone()
                if row is None:
                    raise RuntimeError("Indexer search disappeared")
                if row["status"] == "completed":
                    return json.loads(row["result"])
                if row["status"] == "ambiguous":
                    raise AmbiguousAlbumError(row["error"])
                if row["status"] == "failed":
                    raise RuntimeError(f"Background indexer search failed: {row['error']}")
                if self.worker is not None and not self.worker.is_alive():
                    raise RuntimeError("Background indexer search worker stopped unexpectedly")
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    if self.on_warmed is not None:
                        with closing(self._connect()) as db, db:
                            db.execute(
                                "INSERT OR IGNORE INTO search_retries(query, status) VALUES (?, 'pending')", (key,)
                            )
                    raise SearchWarming("Search is warming in the background; retry later")
                self.condition.wait(remaining)

    def _run(self) -> None:
        while True:
            with self.condition:
                if self.stopping:
                    return
                with closing(self._connect()) as db, db:
                    row = db.execute(
                        "SELECT query FROM searches WHERE status='pending' AND updated <= ? ORDER BY updated LIMIT 1",
                        (time.time(),),
                    ).fetchone()
                    if row is not None:
                        db.execute(
                            "UPDATE searches SET status='running', updated=? WHERE query=?", (time.time(), row[0])
                        )
                if row is None:
                    with closing(self._connect()) as db:
                        retry = db.execute("SELECT MIN(updated) FROM searches WHERE status='pending'").fetchone()[0]
                    self.condition.wait(None if retry is None else max(0, retry - time.time()))
                    continue
            key = row["query"]
            log.info(f"Starting background indexer search: {key}")
            try:
                results = self.callback(**json.loads(key))
                status, result, error = "completed", json.dumps(results), None
            except (DeezerUnavailable, MusicBrainzUnavailable) as exc:
                log.warning(f"Background indexer search will retry: {exc}")
                status, result, error = "pending", None, str(exc)
            except AmbiguousAlbumError as exc:
                status, result, error = "ambiguous", None, str(exc)
            except (Exception, SystemExit) as exc:  # noqa: BLE001 - record failures and keep the worker available.
                log.error(f"Background indexer search failed: {exc}")
                status, result, error = "failed", None, str(exc)
            with self.condition, closing(self._connect()) as db, db:
                db.execute(
                    "UPDATE searches SET status=?, result=?, error=?, updated=? WHERE query=?",
                    (status, result, error, time.time() + (self.retry_seconds if status == "pending" else 0), key),
                )
                if status in ("failed", "ambiguous"):
                    db.execute("DELETE FROM search_retries WHERE query=? AND status='pending'", (key,))
                self.condition.notify_all()
            log.info(f"Background indexer search {status}: {key}")

    def _run_retries(self) -> None:
        on_warmed = self.on_warmed
        if on_warmed is None:
            raise RuntimeError("Automatic search retry is not configured")
        while True:
            with self.condition:
                if self.stopping:
                    return
                with closing(self._connect()) as db, db:
                    row = db.execute(
                        "SELECT searches.query, searches.result FROM searches "
                        "JOIN search_retries ON search_retries.query=searches.query "
                        "WHERE searches.status='completed' AND search_retries.status='pending' "
                        "AND search_retries.retry_after <= ? ORDER BY searches.updated LIMIT 1",
                        (time.time(),),
                    ).fetchone()
                    if row is not None:
                        db.execute("UPDATE search_retries SET status='dispatching' WHERE query=?", (row["query"],))
                if row is None:
                    with closing(self._connect()) as db:
                        retry = db.execute(
                            "SELECT MIN(search_retries.retry_after) FROM search_retries "
                            "JOIN searches ON searches.query=search_retries.query "
                            "WHERE searches.status='completed' AND search_retries.status='pending'"
                        ).fetchone()[0]
                    self.condition.wait(None if retry is None else max(0, retry - time.time()))
                    continue
            try:
                on_warmed(json.loads(row["result"]))
            except SearchRetryDeferred as exc:
                log.info(f"Automatic search retry deferred: {exc}")
                status, error, retry_after = "pending", str(exc), time.time() + self.retry_seconds
            except SearchRetryRejected as exc:
                log.error(f"Automatic search retry was not sent: {exc}")
                status, error, retry_after = "failed", str(exc), 0
            except (Exception, SystemExit) as exc:  # noqa: BLE001 - prevent an uncertain command from being repeated.
                log.error(f"Automatic search retry outcome is uncertain; inspect Lidarr before retrying: {exc}")
                status, error, retry_after = "uncertain", str(exc), 0
            else:
                status, error, retry_after = "submitted", None, 0
            with self.condition, closing(self._connect()) as db, db:
                db.execute(
                    "UPDATE search_retries SET status=?, error=?, retry_after=? WHERE query=?",
                    (status, error, retry_after, row["query"]),
                )
                if status == "submitted":
                    db.execute("UPDATE searches SET updated=? WHERE query=?", (time.time(), row["query"]))
