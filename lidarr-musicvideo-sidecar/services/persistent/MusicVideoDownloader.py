#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

"""MusicVideoDownloader persistent service entry point."""

import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "../..")))
os.environ.setdefault("SCRIPT_NAME", "MusicVideoDownloader")

from python.music_video_downloader.service import main

if __name__ == "__main__":
    main()
