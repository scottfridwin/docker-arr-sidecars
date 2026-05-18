#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

"""Lidarr AutoConfig one-time service.

Extends the shared autoconfig with Lidarr-specific endpoints:
metadata, metadataprofile, metadataProvider.
"""

import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "../..")))
os.environ.setdefault("SCRIPT_NAME", "AutoConfig")

from shared.python.autoconfig import main as shared_main
from shared.python.arrapi import update_arr_config, verify_arr_api_access
from shared.python.config import env, env_bool, env_int
from shared.python.logging_utils import debug, info
from shared.python.state import init_state

import time


def main() -> None:
    info(f"Starting {env('SCRIPT_NAME', 'AutoConfig')}")

    # Log all config vars at debug level
    for key in [
        "AUTOCONFIG_DELAY",
        "AUTOCONFIG_CUSTOMFORMAT",
        "AUTOCONFIG_CUSTOMFORMAT_JSON",
        "AUTOCONFIG_DOWNLOADCLIENT",
        "AUTOCONFIG_DOWNLOADCLIENT_JSON",
        "AUTOCONFIG_HOST",
        "AUTOCONFIG_HOST_JSON",
        "AUTOCONFIG_MEDIAMANAGEMENT",
        "AUTOCONFIG_MEDIAMANAGEMENT_JSON",
        "AUTOCONFIG_METADATA",
        "AUTOCONFIG_METADATA_JSON",
        "AUTOCONFIG_METADATAPROFILE",
        "AUTOCONFIG_METADATAPROFILE_JSON",
        "AUTOCONFIG_METADATAPROVIDER",
        "AUTOCONFIG_METADATAPROVIDER_JSON",
        "AUTOCONFIG_NAMING",
        "AUTOCONFIG_NAMING_JSON",
        "AUTOCONFIG_QUALITYPROFILE",
        "AUTOCONFIG_QUALITYPROFILE_JSON",
        "AUTOCONFIG_UI",
        "AUTOCONFIG_UI_JSON",
    ]:
        debug(f"{key}={env(key, '')}")

    delay = env_int("AUTOCONFIG_DELAY", 0)
    if delay > 0:
        info(
            f"Delaying for {delay} seconds to allow {env('ARR_NAME')} to fully initialize database"
        )
        time.sleep(delay)

    init_state()
    verify_arr_api_access()

    # Shared endpoints (same as Radarr/Sonarr)
    if env_bool("AUTOCONFIG_CUSTOMFORMAT"):
        update_arr_config(
            env("AUTOCONFIG_CUSTOMFORMAT_JSON"), "customformat", "Custom Format(s)"
        )
    if env_bool("AUTOCONFIG_DOWNLOADCLIENT"):
        update_arr_config(
            env("AUTOCONFIG_DOWNLOADCLIENT_JSON"), "downloadclient", "Download Client"
        )
    if env_bool("AUTOCONFIG_HOST"):
        update_arr_config(env("AUTOCONFIG_HOST_JSON"), "config/host", "Host")
    if env_bool("AUTOCONFIG_MEDIAMANAGEMENT"):
        update_arr_config(
            env("AUTOCONFIG_MEDIAMANAGEMENT_JSON"),
            "config/mediamanagement",
            "Media Management",
        )

    # Lidarr-specific endpoints
    if env_bool("AUTOCONFIG_METADATA"):
        update_arr_config(
            env("AUTOCONFIG_METADATA_JSON"), "metadata", "Metadata"
        )
    if env_bool("AUTOCONFIG_METADATAPROFILE"):
        update_arr_config(
            env("AUTOCONFIG_METADATAPROFILE_JSON"),
            "metadataprofile",
            "Metadata Profile",
        )
    if env_bool("AUTOCONFIG_METADATAPROVIDER"):
        update_arr_config(
            env("AUTOCONFIG_METADATAPROVIDER_JSON"),
            "config/metadataProvider",
            "Metadata Provider",
        )

    # Remaining shared endpoints
    if env_bool("AUTOCONFIG_NAMING"):
        update_arr_config(env("AUTOCONFIG_NAMING_JSON"), "config/naming", "Naming")
    if env_bool("AUTOCONFIG_QUALITYPROFILE"):
        update_arr_config(
            env("AUTOCONFIG_QUALITYPROFILE_JSON"),
            "qualityprofile",
            "Quality Profile(s)",
        )
    if env_bool("AUTOCONFIG_UI"):
        update_arr_config(env("AUTOCONFIG_UI_JSON"), "config/ui", "UI")

    info("Auto Configuration Complete")


if __name__ == "__main__":
    main()
