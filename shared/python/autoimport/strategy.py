# SPDX-License-Identifier: GPL-3.0-only
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Callable


def _identity_parse(target_name: str) -> tuple[str, str]:
    return target_name, target_name


@dataclass(frozen=True)
class ImportStrategy:
    resource_endpoint: str
    cache_filename: str
    state_key: str
    # Splits a drop-folder's target name (post-marker) into (match_key,
    # hook_arg). match_key is matched against known resource paths; hook_arg
    # is passed to pre_move_hook. Identity by default (both are the same
    # string) - override when the folder name needs to carry more than the
    # matching key (e.g. Lidarr also needs a release MBID to know which
    # album to tag, since only Artist - not Album - has a path).
    parse_folder_name: Callable[[str], tuple[str, str]] = _identity_parse
    # Called with (import_dir, hook_arg) after a match is found and
    # permissions pass, before the move. Return True to proceed with the
    # move, False to abort (folder is set aside, same as a no-match). No-op
    # by default - only Lidarr uses this, to tag files before import.
    pre_move_hook: Callable[[Path, str], bool] | None = None
    # Called with (dest_dir, hook_arg) after the move into the shared watched
    # import path completes. No-op by default (Radarr/Sonarr rely purely on
    # the arr app's own watchFolder-driven auto-import) - only Lidarr uses
    # this, to trigger a deterministic Manual Import when configured to.
    post_move_hook: Callable[[Path, str], None] | None = None

    def cache_path(self, work_dir: str) -> Path:
        return Path(work_dir) / self.cache_filename

    def match_path(self, target_name: str, paths: list[str]) -> str | None:
        for path in paths:
            if Path(path).name == target_name:
                return path
        return None
