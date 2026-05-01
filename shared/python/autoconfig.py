#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

import time

from .arrapi import update_arr_config, verify_arr_api_access
from .config import env, env_bool, env_int
from .logging_utils import debug, info
from .state import init_state


def main() -> None:
    info(f"Starting {env('SCRIPT_NAME', 'AutoConfig')}")
    debug(f"AUTOCONFIG_DELAY={env('AUTOCONFIG_DELAY')}")
    debug(f"AUTOCONFIG_CUSTOMFORMAT={env('AUTOCONFIG_CUSTOMFORMAT')}")
    debug(f"AUTOCONFIG_CUSTOMFORMAT_JSON={env('AUTOCONFIG_CUSTOMFORMAT_JSON')}")
    debug(f"AUTOCONFIG_DOWNLOADCLIENT={env('AUTOCONFIG_DOWNLOADCLIENT')}")
    debug(f"AUTOCONFIG_DOWNLOADCLIENT_JSON={env('AUTOCONFIG_DOWNLOADCLIENT_JSON')}")
    debug(f"AUTOCONFIG_HOST={env('AUTOCONFIG_HOST')}")
    debug(f"AUTOCONFIG_HOST_JSON={env('AUTOCONFIG_HOST_JSON')}")
    debug(f"AUTOCONFIG_MEDIAMANAGEMENT={env('AUTOCONFIG_MEDIAMANAGEMENT')}")
    debug(f"AUTOCONFIG_MEDIAMANAGEMENT_JSON={env('AUTOCONFIG_MEDIAMANAGEMENT_JSON')}")
    debug(f"AUTOCONFIG_NAMING={env('AUTOCONFIG_NAMING')}")
    debug(f"AUTOCONFIG_NAMING_JSON={env('AUTOCONFIG_NAMING_JSON')}")
    debug(f"AUTOCONFIG_QUALITYPROFILE={env('AUTOCONFIG_QUALITYPROFILE')}")
    debug(f"AUTOCONFIG_QUALITYPROFILE_JSON={env('AUTOCONFIG_QUALITYPROFILE_JSON')}")
    debug(f"AUTOCONFIG_REMOTEPATHMAPPING={env('AUTOCONFIG_REMOTEPATHMAPPING')}")
    debug(
        f"AUTOCONFIG_REMOTEPATHMAPPING_JSON={env('AUTOCONFIG_REMOTEPATHMAPPING_JSON')}"
    )
    debug(f"AUTOCONFIG_UI={env('AUTOCONFIG_UI')}")
    debug(f"AUTOCONFIG_UI_JSON={env('AUTOCONFIG_UI_JSON')}")

    delay = env_int("AUTOCONFIG_DELAY", 0)
    if delay > 0:
        info(
            f"Delaying for {delay} seconds to allow {env('ARR_NAME')} to fully initialize database"
        )
        time.sleep(delay)

    init_state()
    verify_arr_api_access()

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
    if env_bool("AUTOCONFIG_NAMING"):
        update_arr_config(env("AUTOCONFIG_NAMING_JSON"), "config/naming", "Naming")
    if env_bool("AUTOCONFIG_QUALITYPROFILE"):
        update_arr_config(
            env("AUTOCONFIG_QUALITYPROFILE_JSON"),
            "qualityprofile",
            "Quality Profile(s)",
        )
    if env_bool("AUTOCONFIG_REMOTEPATHMAPPING"):
        update_arr_config(
            env("AUTOCONFIG_REMOTEPATHMAPPING_JSON"),
            "remotepathmapping",
            "Remote Path Mapping",
        )
    if env_bool("AUTOCONFIG_UI"):
        update_arr_config(env("AUTOCONFIG_UI_JSON"), "config/ui", "UI")

    info("Auto Configuration Complete")


if __name__ == "__main__":
    main()
