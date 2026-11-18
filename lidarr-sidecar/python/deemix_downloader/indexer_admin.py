#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

"""Local operator commands for quota-waiting Lidarr indexer jobs."""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
from pathlib import Path

from .indexer_bridge import BridgeStore
from .quota import DailyDownloadQuota


def _require_initialized_state(work_path: Path) -> None:
    required = (
        work_path / "indexer_jobs.sqlite3",
        work_path / "daily_download_quota.sqlite3",
        work_path / "daily_download_quota.lock",
    )
    if not all(path.is_file() for path in required):
        raise RuntimeError("indexer state is not initialized; start the indexer before using this command")
    if required[2].read_bytes() != b"ready":
        raise RuntimeError("quota state is not ready; no override was granted")


def _open_state(work_path: Path, limit: int) -> tuple[BridgeStore, DailyDownloadQuota]:
    _require_initialized_state(work_path)
    return BridgeStore(work_path / "indexer_jobs.sqlite3"), DailyDownloadQuota(work_path, limit)


def list_waiting_jobs(work_path: Path, limit: int) -> list[tuple[int, str, str]]:
    """Return jobs blocked by the quota, including queued jobs when the quota is full."""
    store, quota = _open_state(work_path, limit)
    statuses = ("queued", "waiting_quota") if quota.snapshot().full else ("waiting_quota",)
    results = []
    for row in store.jobs(statuses):
        payload = json.loads(row["payload"])
        title = f"{payload['artist_name']} - {payload['album_title']}".replace("\r", " ").replace("\n", " ")
        results.append((row["nzb_id"], row["status"], title))
    return results


def grant_quota_override(
    work_path: Path,
    limit: int,
    nzb_id: int,
    actor: str,
    reason: str,
) -> str:
    """Grant an unused quota exception for one queued job attempt."""
    if nzb_id <= 0:
        raise ValueError("NZB ID must be a positive integer")
    store, quota = _open_state(work_path, limit)
    job = store.get_job_by_nzb_id(nzb_id)
    if not job or job["status"] not in ("queued", "waiting_quota"):
        raise ValueError(f"NZB ID {nzb_id} is not queued or waiting for quota")
    if not quota.snapshot().full:
        raise ValueError("daily download quota is not currently full")
    release = store.get_release_for_job(job["id"])
    attempt_id = f"{job['id']}:{release['attempt']}"
    quota.grant_override(attempt_id, actor, reason)
    return f"Granted one-time quota override for NZB ID {nzb_id}: {release['artist_name']} - {release['album_title']}"


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Manage waiting Lidarr indexer downloads.")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("list-waiting", help="list NZB IDs waiting or queued behind the daily quota")
    grant = commands.add_parser("grant-quota-override", help="allow one queued attempt beyond today's quota")
    grant.add_argument("--nzb-id", type=int, required=True, help="NZB ID from list-waiting")
    grant.add_argument("--operator", required=True, help="operator name recorded in the quota audit")
    grant.add_argument("--reason", required=True, help="short reason for the one-time exception")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = _parser()
    args = parser.parse_args(argv)
    work_path = Path(os.environ.get("AUDIO_WORK_PATH", "/work"))
    try:
        limit = int(os.environ.get("AUDIO_DAILY_DOWNLOAD_LIMIT", "0"))
        if args.command == "list-waiting":
            jobs = list_waiting_jobs(work_path, limit)
            if not jobs:
                print("No jobs are waiting for quota.")
            else:
                print("NZB ID\tStatus\tAlbum")
                for nzb_id, status, title in jobs:
                    print(f"{nzb_id}\t{status}\t{title}")
            return 0
        message = grant_quota_override(work_path, limit, args.nzb_id, args.operator, args.reason)
        print(message)
        return 0
    except (OSError, sqlite3.Error, RuntimeError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
