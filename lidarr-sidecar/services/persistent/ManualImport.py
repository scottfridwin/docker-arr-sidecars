#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

"""ManualImport persistent service entry point.

Reuses shared.python.autoimport (the same mechanism Radarr/Sonarr's
AutoImport uses): watches AUTOIMPORT_DROP_DIR for marked folders, matches
them against known Lidarr artist paths, tags files in place via a
Lidarr-specific pre-move hook, then moves them into Lidarr's watched import
path so its own DownloadedAlbumsScan/download-client polling imports them -
for user-supplied albums (e.g. CD rips) not available on Deezer.
"""

import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "../..")))
os.environ["SCRIPT_NAME"] = "ManualImport"

from shared.python.autoimport.runner import main
from shared.python.autoimport.strategy import ImportStrategy

from python.deemix_downloader.service import (
    manual_import_pre_move_hook,
    parse_manual_import_folder_name,
    setup_beets,
)


def lidarr_manual_import_strategy() -> ImportStrategy:
    # Matches against Artist paths (Lidarr's Album resource has no path of
    # its own), and tags files via manual_import_pre_move_hook before they're
    # moved into Lidarr's watched import path - same end-to-end flow as
    # Radarr/Sonarr's AutoImport, just with a Lidarr-specific tagging step.
    return ImportStrategy(
        resource_endpoint="artist",
        cache_filename="artistpaths",
        state_key="artistPaths",
        parse_folder_name=parse_manual_import_folder_name,
        pre_move_hook=manual_import_pre_move_hook,
    )


if __name__ == "__main__":
    setup_beets()
    main(lidarr_manual_import_strategy())
