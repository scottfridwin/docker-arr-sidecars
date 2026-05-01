#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
os.environ["SCRIPT_NAME"] = "AutoImport"

from shared.python.autoimport.runner import main
from shared.python.autoimport.strategy import ImportStrategy


def radarr_strategy() -> ImportStrategy:
    return ImportStrategy(
        resource_endpoint="movie",
        cache_filename="moviepaths",
        state_key="moviePaths",
    )


if __name__ == "__main__":
    main(radarr_strategy())
