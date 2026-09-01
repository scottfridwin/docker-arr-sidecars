#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

"""ManualImport persistent service entry point.

Watches AUDIO_MANUAL_IMPORT_DROP_DIR for user-supplied albums (e.g. CD rips
not available on Deezer), applies the same MusicBrainz/ReplayGain/Beets
tagging as a normal deemix download, and forces a Lidarr Manual Import.
"""

import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "../..")))
os.environ.setdefault("SCRIPT_NAME", "ManualImport")

from python.deemix_downloader.service import manual_import_loop

if __name__ == "__main__":
    manual_import_loop()
