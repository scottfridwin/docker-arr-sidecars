# SPDX-License-Identifier: GPL-3.0-only
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable


@dataclass(frozen=True)
class ImportStrategy:
    resource_endpoint: str
    cache_filename: str
    state_key: str
    push_release_enabled: bool
    push_release_payload: Callable[[str], str]
    notify_payload: Callable[[str], str]

    def cache_path(self, work_dir: str) -> Path:
        return Path(work_dir) / self.cache_filename

    def match_path(self, target_name: str, paths: list[str]) -> str | None:
        needle = f"/{target_name}"
        for path in paths:
            if needle in path:
                return path
        return None


def sonarr_strategy() -> ImportStrategy:
    return ImportStrategy(
        resource_endpoint="series",
        cache_filename="seriepaths",
        state_key="seriesPaths",
        push_release_enabled=True,
        push_release_payload=lambda title: (
            "{"
            '"title":"' + title + '",'
            '"downloadUrl":"http://localhost/fake.nzb",'
            '"protocol":"usenet",'
            '"publishDate":"'
            + datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            + '",'
            '"indexer":"sidecar",'
            '"downloadClient":"sonarr-sidecar"'
            "}"
        ),
        notify_payload=lambda import_path: '{"name":"ProcessMonitoredDownloads"}',
    )


def radarr_strategy() -> ImportStrategy:
    return ImportStrategy(
        resource_endpoint="movie",
        cache_filename="moviepaths",
        state_key="moviePaths",
        push_release_enabled=False,
        push_release_payload=lambda title: "{}",
        notify_payload=lambda import_path: (
            '{"name":"DownloadedMoviesScan", "path":"' + import_path + '"}'
        ),
    )
