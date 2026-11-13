#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

"""Newznab indexer and NZBGet-compatible Deemix download bridge."""

import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "../..")))
os.environ.setdefault("SCRIPT_NAME", "Indexer")

from python.deemix_downloader.service import indexer_main

if __name__ == "__main__":
    indexer_main()
