#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

import os
import sys

# Ensure /app is on the Python path so shared modules can be imported
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
os.environ["SCRIPT_NAME"] = "AutoConfig"

from shared.python.autoconfig import main

if __name__ == "__main__":
    main()
