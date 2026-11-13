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

from .indexer_search import AmbiguousAlbumError
from .logging import log


class SearchWarming(RuntimeError):
    """Search metadata is still being collected."""


class BackgroundSearch:
    def __init__(
        self, work_path: str | Path, search: Callable[..., list[dict[str, Any]]], *, wait_seconds: float = 10.0
    ):
        self.path = Path(work_path) / "indexer_searches.sqlite3"
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.callback = search
        self.wait_seconds = wait_seconds
        self.condition = threading.Condition()
        self.stopping = False
        self.worker: threading.Thread | None = None
        with closing(self._connect()) as db, db:
            db.execute(
                "CREATE TABLE IF NOT EXISTS searches ("
                "query TEXT PRIMARY KEY, status TEXT NOT NULL, result TEXT, error TEXT, updated REAL NOT NULL)"
            )
            version = db.execute("PRAGMA user_version").fetchone()[0]
            if version in (0, 1, 2, 3, 4, 5):
                db.execute("DELETE FROM searches WHERE status IN ('completed', 'failed', 'ambiguous')")
                db.execute("PRAGMA user_version=6")
            elif version != 6:
                raise RuntimeError(f"Unsupported indexer search database version: {version}")
            db.execute("UPDATE searches SET status='pending' WHERE status='running'")

    def _connect(self) -> sqlite3.Connection:
        db = sqlite3.connect(self.path, timeout=30)
        db.row_factory = sqlite3.Row
        return db

    def start(self) -> threading.Thread:
        worker = threading.Thread(target=self._run, name="indexer-search-worker", daemon=True)
        self.worker = worker
        worker.start()
        return worker

    def stop(self) -> None:
        with self.condition:
            self.stopping = True
            self.condition.notify_all()

    def search(self, **query: Any) -> list[dict[str, Any]]:
        key = json.dumps(query, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
        deadline = time.monotonic() + self.wait_seconds
        with self.condition:
            with closing(self._connect()) as db, db:
                db.execute(
                    "DELETE FROM searches WHERE status IN ('completed', 'failed', 'ambiguous') AND updated < ?",
                    (time.time() - 300,),
                )
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
                    raise SearchWarming("Search is warming in the background; retry later")
                self.condition.wait(remaining)

    def _run(self) -> None:
        while True:
            with self.condition:
                if self.stopping:
                    return
                with closing(self._connect()) as db, db:
                    row = db.execute(
                        "SELECT query FROM searches WHERE status='pending' ORDER BY updated LIMIT 1"
                    ).fetchone()
                    if row is not None:
                        db.execute(
                            "UPDATE searches SET status='running', updated=? WHERE query=?", (time.time(), row[0])
                        )
                if row is None:
                    self.condition.wait()
                    continue
            key = row["query"]
            log.info(f"Starting background indexer search: {key}")
            try:
                results = self.callback(**json.loads(key))
                status, result, error = "completed", json.dumps(results), None
            except AmbiguousAlbumError as exc:
                status, result, error = "ambiguous", None, str(exc)
            except Exception as exc:  # noqa: BLE001 - record failures and keep the search worker available.
                log.error(f"Background indexer search failed: {exc}")
                status, result, error = "failed", None, str(exc)
            with self.condition, closing(self._connect()) as db, db:
                db.execute(
                    "UPDATE searches SET status=?, result=?, error=?, updated=? WHERE query=?",
                    (status, result, error, time.time(), key),
                )
                self.condition.notify_all()
            log.info(f"Background indexer search {status}: {key}")
