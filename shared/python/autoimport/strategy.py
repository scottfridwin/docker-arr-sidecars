# SPDX-License-Identifier: GPL-3.0-only
from __future__ import annotations

from dataclasses import dataclass
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
