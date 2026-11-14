#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

"""Optionally register the Deemix indexer and its dedicated NZBGet client."""

import json
import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "../..")))
os.environ.setdefault("SCRIPT_NAME", "IndexerConfig")

from shared.python.arrapi import arr_api_request, verify_arr_api_access
from shared.python.config import env, env_bool
from shared.python.logging_utils import fatal, info
from shared.python.state import get_state, init_state


def _request(method: str, path: str, payload: dict | None = None):
    arr_api_request(method, path, json.dumps(payload) if payload is not None else None)
    return get_state("arrApiResponse")


def _schema(path: str, implementation: str) -> dict:
    schemas = _request("GET", path)
    if not isinstance(schemas, list):
        fatal(f"Lidarr returned an invalid {path} response")
    schema = next((item for item in schemas if item.get("implementation") == implementation), None)
    if schema is None:
        fatal(f"Lidarr does not support {implementation}")
    return schema


def _payload(schema: dict, values: dict[str, object], name: str) -> dict:
    return {
        "enable": True,
        "name": name,
        "implementation": schema["implementation"],
        "implementationName": schema["implementationName"],
        "configContract": schema["configContract"],
        "protocol": schema["protocol"],
        "priority": 10,
        "tags": [],
        "fields": [
            {"name": field["name"], "value": values.get(field["name"], field.get("value"))}
            for field in schema.get("fields", [])
        ],
    }


def _upsert(path: str, payload: dict) -> dict:
    existing_resources = _request("GET", path)
    if not isinstance(existing_resources, list):
        fatal(f"Lidarr returned an invalid resource list for {path}")
    existing = next((item for item in existing_resources if item.get("name") == payload["name"]), None)
    if existing is None:
        if path == "indexer":
            search_modes = {
                key: payload[key] for key in ("enableRss", "enableAutomaticSearch", "enableInteractiveSearch")
            }
            # Lidarr's provider test issues an unscoped search, which correctly has no results here.
            payload["enable"] = False
            payload.update({key: False for key in search_modes})
            response = _request("POST", path, payload)
            if not isinstance(response, dict) or not response.get("id"):
                fatal(f"Lidarr did not return the configured resource ID for {payload['name']}")
            payload["id"] = response["id"]
            payload["enable"] = True
            payload.update(search_modes)
            response = _request("PUT", f"{path}/{response['id']}?forceSave=true", payload)
        else:
            response = _request("POST", path, payload)
    else:
        payload["id"] = existing["id"]
        suffix = "?forceSave=true" if path == "indexer" else ""
        response = _request("PUT", f"{path}/{existing['id']}{suffix}", payload)
    if isinstance(response, dict) and response.get("id"):
        return response
    fatal(f"Lidarr did not return the configured resource ID for {payload['name']}")


def main() -> None:
    if not env_bool("AUTOCONFIG_DEEMIX_INDEXER"):
        return

    if not env_bool("SERVICE_INDEXER_ENABLED") or env_bool("SERVICE_DEEMIXDOWNLOADER_ENABLED", True):
        fatal("Deemix indexer auto-configuration requires the indexer enabled and the legacy downloader disabled")

    api_key = env("AUDIO_INDEXER_API_KEY")
    client_password = env("AUDIO_INDEXER_CLIENT_PASSWORD")
    public_url = env("AUDIO_INDEXER_PUBLIC_URL").rstrip("/")
    if len(api_key) < 32 or len(client_password) < 16 or not public_url:
        fatal("Deemix indexer auto-configuration requires its URL, API key, and download-client password")

    init_state()
    verify_arr_api_access()
    client_host = env("AUDIO_INDEXER_CLIENT_HOST", "lidarr-sidecar")
    client_port = int(env("AUDIO_INDEXER_CLIENT_PORT") or env("AUDIO_INDEXER_PORT", "9797"))
    use_ssl = env_bool("AUDIO_INDEXER_CLIENT_USE_SSL")
    client_schema = _schema("downloadclient/schema", "Nzbget")
    client_payload = _payload(
        client_schema,
        {
            "host": client_host,
            "port": client_port,
            "useSsl": use_ssl,
            "urlBase": "",
            "username": env("AUDIO_INDEXER_CLIENT_USERNAME", "lidarr-sidecar"),
            "password": client_password,
            "musicCategory": "Music",
            "recentMusicPriority": 0,
            "olderMusicPriority": 0,
            "addPaused": False,
        },
        env("AUDIO_INDEXER_CLIENT_NAME", "Deemix NZBGet Bridge"),
    )
    client_payload.update({"removeCompletedDownloads": False, "removeFailedDownloads": False})
    client = _upsert("downloadclient", client_payload)

    indexer_schema = _schema("indexer/schema", "Newznab")
    indexer_payload = _payload(
        indexer_schema,
        {
            "baseUrl": public_url,
            "apiPath": "/api",
            "apiKey": api_key,
            "categories": [3000, 3010, 3030, 3040],
            "earlyReleaseLimit": None,
            "additionalParameters": None,
        },
        env("AUDIO_INDEXER_NAME", "Deemix Newznab Indexer"),
    )
    indexer_payload.update(
        {
            "enableRss": False,
            "enableAutomaticSearch": True,
            "enableInteractiveSearch": True,
            "downloadClientId": client["id"],
            "supportsRss": True,
            "supportsSearch": True,
        }
    )
    _upsert("indexer", indexer_payload)
    info("Deemix Newznab indexer and dedicated NZBGet client configured")


def run_one_time() -> None:
    if not env_bool("AUTOCONFIG_DEEMIX_INDEXER"):
        return
    if not env_bool("SERVICE_INDEXER_ENABLED") or env_bool("SERVICE_DEEMIXDOWNLOADER_ENABLED", True):
        fatal("Deemix indexer auto-configuration requires the indexer enabled and the legacy downloader disabled")
    info("Deemix indexer auto-configuration deferred until the bridge is listening")


if __name__ == "__main__":
    if sys.argv[1:] == ["--bridge-ready"]:
        main()
    else:
        run_one_time()
