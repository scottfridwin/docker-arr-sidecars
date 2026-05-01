#!/usr/bin/env python3
import os
import unittest
from unittest.mock import patch

from shared.python.autoconfig import main


class TestAutoConfig(unittest.TestCase):
    def setUp(self):
        self.env_backup = dict(os.environ)

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.env_backup)

    @patch("shared.python.autoconfig.verify_arr_api_access")
    @patch("shared.python.autoconfig.update_arr_config")
    @patch("shared.python.autoconfig.time.sleep", return_value=None)
    def test_main_calls_update_arr_config_for_enabled_settings(
        self, sleep_mock, update_mock, verify_mock
    ):
        os.environ.update(
            {
                "AUTOCONFIG_DELAY": "0",
                "AUTOCONFIG_CUSTOMFORMAT": "true",
                "AUTOCONFIG_CUSTOMFORMAT_JSON": "/app/config/customformat.json",
                "AUTOCONFIG_DOWNLOADCLIENT": "true",
                "AUTOCONFIG_DOWNLOADCLIENT_JSON": "/app/config/downloadclient.json",
                "AUTOCONFIG_HOST": "true",
                "AUTOCONFIG_HOST_JSON": "/app/config/host.json",
                "AUTOCONFIG_MEDIAMANAGEMENT": "true",
                "AUTOCONFIG_MEDIAMANAGEMENT_JSON": "/app/config/mediamanagement.json",
                "AUTOCONFIG_NAMING": "true",
                "AUTOCONFIG_NAMING_JSON": "/app/config/naming.json",
                "AUTOCONFIG_QUALITYPROFILE": "true",
                "AUTOCONFIG_QUALITYPROFILE_JSON": "/app/config/qualityprofile.json",
                "AUTOCONFIG_REMOTEPATHMAPPING": "true",
                "AUTOCONFIG_REMOTEPATHMAPPING_JSON": "/app/config/remotepathmapping.json",
                "AUTOCONFIG_UI": "true",
                "AUTOCONFIG_UI_JSON": "/app/config/ui.json",
                "ARR_NAME": "sonarr",
            }
        )

        main()

        self.assertEqual(verify_mock.call_count, 1)
        self.assertEqual(update_mock.call_count, 8)
        update_mock.assert_any_call(
            "/app/config/customformat.json", "customformat", "Custom Format(s)"
        )
        update_mock.assert_any_call("/app/config/host.json", "config/host", "Host")
        update_mock.assert_any_call("/app/config/ui.json", "config/ui", "UI")
        sleep_mock.assert_not_called()

    @patch("shared.python.autoconfig.verify_arr_api_access")
    @patch("shared.python.autoconfig.update_arr_config")
    @patch("shared.python.autoconfig.time.sleep", return_value=None)
    def test_main_respects_delay(self, sleep_mock, update_mock, verify_mock):
        os.environ.update(
            {
                "AUTOCONFIG_DELAY": "5",
                "AUTOCONFIG_CUSTOMFORMAT": "false",
                "AUTOCONFIG_DOWNLOADCLIENT": "false",
                "AUTOCONFIG_HOST": "false",
                "AUTOCONFIG_MEDIAMANAGEMENT": "false",
                "AUTOCONFIG_NAMING": "false",
                "AUTOCONFIG_QUALITYPROFILE": "false",
                "AUTOCONFIG_REMOTEPATHMAPPING": "false",
                "AUTOCONFIG_UI": "false",
                "ARR_NAME": "radarr",
            }
        )

        main()

        sleep_mock.assert_called_once_with(5)
        verify_mock.assert_called_once()
        update_mock.assert_not_called()
