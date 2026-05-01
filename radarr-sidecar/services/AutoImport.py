#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
os.environ.setdefault("SCRIPT_NAME", "AutoImport")

from shared.python.autoimport.radarr import main

if __name__ == "__main__":
    main()
