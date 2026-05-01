#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

from shared.python.autoimport.strategy import ImportStrategy


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
