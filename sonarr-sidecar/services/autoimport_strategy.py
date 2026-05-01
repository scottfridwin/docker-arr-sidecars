#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

from datetime import datetime, timezone

from shared.python.autoimport.strategy import ImportStrategy


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
