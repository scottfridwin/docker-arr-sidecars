#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

import os
import sys
from datetime import datetime, timezone

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
os.environ.setdefault("SCRIPT_NAME", "AutoImport")

from shared.python.autoimport.runner import main
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


if __name__ == "__main__":
    main(sonarr_strategy())
