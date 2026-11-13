# SPDX-License-Identifier: GPL-3.0-only
"""Reclaim substantial unused SQLite space during periodic maintenance."""

import sqlite3
from pathlib import Path


def compact_if_needed(path: Path) -> None:
    connection = sqlite3.connect(path.resolve().as_uri() + "?mode=rw", uri=True, timeout=1)
    try:
        page_size = connection.execute("PRAGMA page_size").fetchone()[0]
        free_pages = connection.execute("PRAGMA freelist_count").fetchone()[0]
        if page_size * free_pages >= 1024 * 1024:
            connection.execute("VACUUM")
    finally:
        connection.close()
