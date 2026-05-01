#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only

import json
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from .config import env, env_bool
from .io_utils import load_json_text, parse_xml_config, read_json_file, xml_text
from .logging_utils import debug, fatal, info, log, warning
from .state import get_state, init_state, set_state


def get_arr_api_key() -> str:
    arr_api_key = get_state("arrApiKey")
    if arr_api_key:
        return arr_api_key

    root = parse_xml_config(env("ARR_CONFIG_PATH"))
    arr_api_key = xml_text(root, "Config", "ApiKey")
    if not arr_api_key:
        fatal("Failed to extract ApiKey from ARR_CONFIG_PATH")
    set_state("arrApiKey", arr_api_key)
    return arr_api_key


def normalize_url_base(value: str) -> str:
    if not value or value.lower() == "null":
        return ""
    cleaned = value.strip().strip("/")
    return f"/{cleaned}" if cleaned else ""


def get_arr_url() -> str:
    arr_url = get_state("arrUrl")
    if arr_url:
        return arr_url

    root = parse_xml_config(env("ARR_CONFIG_PATH"))
    arr_url_base = normalize_url_base(xml_text(root, "Config", "UrlBase"))

    arr_host = env("ARR_HOST").strip()
    if not arr_host:
        fatal("ARR_HOST is required")

    arr_port = env("ARR_PORT").strip()
    if not arr_port or arr_port.lower() == "null":
        arr_port = xml_text(root, "Config", "Port")
    if not arr_port or not arr_port.isdigit():
        fatal(f"Invalid or missing port value: '{arr_port}'")

    arr_url = f"http://{arr_host}:{arr_port}{arr_url_base}"
    set_state("arrUrl", arr_url)
    return arr_url


def http_request(method: str, url: str, payload: str | None = None):
    headers = {"X-Api-Key": get_arr_api_key()}
    data = None
    if payload is not None:
        headers["Content-Type"] = "application/json"
        data = payload.encode("utf-8")

    timeout = int(env("ARR_API_TIMEOUT", "60"))
    request_obj = Request(url, data=data, headers=headers, method=method)
    debug(
        f"TRACE :: HTTP request method='{method}', url='{url}', timeout={timeout}"
    )
    try:
        with urlopen(request_obj, timeout=timeout) as response:
            body = response.read()
            debug(
                f"TRACE :: HTTP response from {url}: status={response.getcode()} body_length={len(body)}"
            )
            return response.getcode(), body
    except HTTPError as exc:
        body = exc.read()
        debug(
            f"TRACE :: HTTPError for {method} {url} status={exc.code} message={exc.reason}"
        )
        return exc.code, body
    except URLError as exc:
        debug(f"TRACE :: URLError for {method} {url}: {exc}")
        raise
    except OSError as exc:
        debug(f"TRACE :: OSError during HTTP request for {method} {url}: {exc}")
        raise


def get_functional_test_response(method: str, path: str):
    test_dir = Path(env("FUNCTIONALTESTDIR"))
    file_name = f"{method}_{path.replace('/', '_')}.json"
    response_file = test_dir / "ArrApiRequestResponses" / file_name
    if not response_file.is_file():
        fatal(f"Response file not found for functional test: {response_file}")
    return 200, response_file.read_text(encoding="utf-8")


def arr_task_status_check() -> None:
    alerted = False
    while True:
        arr_api_request("GET", "command")
        task_list = get_state("arrApiResponse")
        if not isinstance(task_list, list):
            fatal(f"{env('ARR_NAME')} API returned invalid task list for command")

        active = sum(
            1
            for item in task_list
            if isinstance(item, dict) and item.get("status") == "started"
        )
        if active >= 1:
            if not alerted:
                alerted = True
                info(
                    f"{env('ARR_NAME')} busy :: Waiting for {active} active {env('ARR_NAME')} tasks to complete..."
                )
            time.sleep(2)
            continue
        break


def verify_arr_api_access() -> None:
    debug("TRACE :: Entering verifyArrApiAccess...")
    get_arr_api_key()
    get_arr_url()

    arr_url = get_state("arrUrl")
    arr_api_key = get_state("arrApiKey")
    if not arr_url or not arr_api_key:
        fatal("verifyArrApiAccess requires both URL and API key")

    supported_versions = [
        version.strip()
        for version in env("ARR_SUPPORTED_API_VERSIONS", "v3,v1").split(",")
        if version.strip()
    ]
    if not supported_versions:
        supported_versions = ["v3", "v1"]

    for version in supported_versions:
        if env("FUNCTIONALTESTDIR"):
            debug(
                f"Skipping actual API connectivity test in functional testing mode for version {version}"
            )
            set_state("arrApiVersion", version)
            break

        test_url = f"{arr_url}/api/{version}/system/status?apikey={arr_api_key}"
        debug(f'Attempting connection to "{test_url}"...')

        while True:
            try:
                status_code, body = http_request("GET", test_url)
            except URLError as exc:
                warning(f"curl failed (unreachable) — retrying in 5s... ({exc})")
                time.sleep(5)
                continue

            if status_code == 200:
                parsed = load_json_text(body, "system/status response")
                instance_name = (
                    parsed.get("instanceName") if isinstance(parsed, dict) else ""
                )
                set_state("arrApiVersion", version)
                debug(
                    f"{env('ARR_NAME')} API {version} available (instance: {instance_name})"
                )
                break
            if status_code == 000:
                warning(f"{env('ARR_NAME')} unreachable — retrying in 5s...")
                time.sleep(5)
                continue

            debug(f"{env('ARR_NAME')} returned HTTP {status_code} for v{version}")
            if body and "error" in body.lower():
                debug(f"API error response: {body[:300]}")
            break

        if get_state("arrApiVersion"):
            break

    if not get_state("arrApiVersion"):
        fatal(
            f"Unable to connect to {env('ARR_NAME')} with any supported API versions. Supported: {env('ARR_SUPPORTED_API_VERSIONS')}"
        )

    debug(
        f"{env('ARR_NAME')} API access verified (URL: {arr_url}, Version: {get_state('arrApiVersion')})"
    )
    debug("TRACE :: Exiting verifyArrApiAccess...")


def arr_api_request(method: str, path: str, payload: str | None = None) -> None:
    if (
        not get_state("arrUrl")
        or not get_state("arrApiKey")
        or not get_state("arrApiVersion")
    ):
        debug(
            "Need to retrieve arr connection details in order to perform API requests"
        )
        verify_arr_api_access()

    arr_url = get_state("arrUrl")
    arr_api_version = get_state("arrApiVersion")
    full_url = f"{arr_url}/api/{arr_api_version}/{path}"

    if method.upper() != "GET":
        arr_task_status_check()

    if env("FUNCTIONALTESTDIR"):
        debug(
            f"Skipping actual API request in functional testing mode for {method} {path}"
        )
        status_code, body = get_functional_test_response(method, path)
        if isinstance(body, str):
            body = body.encode("utf-8")
    else:
        if payload is not None:
            debug(
                f"TRACE :: Executing {env('ARR_NAME')} Api call: method '{method}', url: '{full_url}', payload: {payload}"
            )
        else:
            debug(
                f"TRACE :: Executing {env('ARR_NAME')} Api call: method '{method}', url: '{full_url}'"
            )
        while True:
            try:
                status_code, body = http_request(method.upper(), full_url, payload)
            except URLError:
                warning(f"{env('ARR_NAME')} unreachable — entering recovery loop...")
                while True:
                    time.sleep(5)
                    recovery_url = f"{arr_url}/api/{arr_api_version}/system/status"
                    try:
                        recovery_code, recovery_body = http_request("GET", recovery_url)
                    except URLError:
                        continue
                    debug(
                        f"{env('ARR_NAME')} status request ({recovery_url}) returned {recovery_code} with body {recovery_body}"
                    )
                    if recovery_code == 200:
                        debug(
                            f"{env('ARR_NAME')} connectivity restored, retrying previous request..."
                        )
                        break
                continue
            break

    set_state("arrApiReponseCode", status_code)
    parsed_body = None
    if body:
        parsed_body = load_json_text(body, f"API response for {method} {path}")
    set_state("arrApiResponse", parsed_body)
    log("TRACE", f"httpCode: {status_code}")
    if isinstance(body, bytes):
        body_summary = body[:512].decode("utf-8", errors="replace")
        if len(body) > 512:
            body_summary += f"... [truncated {len(body)} bytes]"
    else:
        body_summary = body if len(body) <= 512 else f"{body[:512]}... [truncated {len(body)} bytes]"
    log("TRACE", f"body: {body_summary}")

    if status_code in (200, 201, 202, 204):
        return

    fatal(f"{env('ARR_NAME')} API call failed (HTTP {status_code}) for {method} {path}")


def ids_equal(a, b) -> bool:
    if a is None or b is None:
        return False
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return a == b
    a_str = str(a).strip()
    b_str = str(b).strip()
    if a_str.isdigit() and b_str.isdigit():
        return int(a_str) == int(b_str)
    return a_str == b_str


def compare_values(key, payload_value, response_value, prefix=""):
    mismatches = []
    path = f"{prefix}.{key}" if prefix else key

    if key == "fields" and isinstance(payload_value, list):
        if not isinstance(response_value, list):
            return [
                f"Value mismatch: {path} (expected list of fields, got {type(response_value).__name__})"
            ]
        for field in payload_value:
            if not isinstance(field, dict) or "name" not in field:
                return [f"Invalid field entry in payload at {path}"]
            name = field["name"]
            matches = [
                item
                for item in response_value
                if isinstance(item, dict) and item.get("name") == name
            ]
            if not matches:
                mismatches.append(f"Missing field: {name}")
                continue
            for match in matches:
                if match.get("value") != field.get("value"):
                    mismatches.append(
                        f"Value mismatch in field {name} (expected: {field.get('value')}, got: {match.get('value')})"
                    )
        return mismatches

    if isinstance(payload_value, dict):
        if not isinstance(response_value, dict):
            return [
                f"Value mismatch: {path} (expected object, got {type(response_value).__name__})"
            ]
        for subkey, subval in payload_value.items():
            mismatches.extend(
                compare_values(subkey, subval, response_value.get(subkey), path)
            )
        return mismatches

    if isinstance(payload_value, list):
        if payload_value != response_value:
            return [
                f"Value mismatch: {path} (expected: {payload_value}, got: {response_value})"
            ]
        return []

    if response_value != payload_value:
        return [
            f"Value mismatch: {path} (expected: {payload_value}, got: {response_value})"
        ]
    return []


def response_matches_payload(payload, response) -> bool:
    if payload is None or response is None:
        fatal("responseMatchesPayload called with empty payload or response")
    if not isinstance(payload, dict):
        return True
    if not isinstance(response, dict):
        fatal("responseMatchesPayload received a non-object response")
    mismatches = []
    for key, value in payload.items():
        mismatches.extend(compare_values(key, value, response.get(key)))

    if mismatches:
        debug("TRACE :: Found differences between payload and response:")
        for line in mismatches:
            debug(f"TRACE :: {line}")
        return False
    return True


def arr_api_attempt(method: str, url: str, payload: str) -> None:
    max_attempts = 5
    attempt = 1

    while True:
        arr_api_request(method, url, payload)
        resp = get_state("arrApiResponse")

        if isinstance(resp, (dict, list)):
            if response_matches_payload(json.loads(payload), resp):
                break
        else:
            if method.upper() == "PUT":
                debug(f"Empty or invalid response to PUT; fetching {url} to verify...")
                arr_api_request("GET", url)
                resp = get_state("arrApiResponse")
                if not isinstance(resp, (dict, list)):
                    fatal(f"Invalid JSON received from GET {url} during verification.")
                if response_matches_payload(json.loads(payload), resp):
                    break
            else:
                debug(
                    f"Empty or invalid response to {method} at {url}; skipping verification for this attempt."
                )
                break

        if attempt >= max_attempts:
            fatal(
                f"{env('ARR_NAME')} response does not reflect requested changes for {url} after {attempt} attempts."
            )

        warning(
            f"{env('ARR_NAME')} response mismatch for {url}; retrying in 5s ({attempt}/{max_attempts})..."
        )
        time.sleep(5)
        attempt += 1


def update_arr_config(json_file: str, api_path: str, setting_name: str) -> None:
    json_data = read_json_file(json_file)
    debug(f"Configuring {env('ARR_NAME')} {setting_name} Settings")

    if isinstance(json_data, list):
        debug("Detected JSON array, sending one PUT/POST per element...")
        arr_api_request("GET", api_path)
        response = get_state("arrApiResponse")

        if response is None:
            fatal(f"Empty API response when fetching existing resources at {api_path}")
        if not isinstance(response, list):
            fatal(
                f"Expected array response when fetching existing resources at {api_path}"
            )

        for item in json_data:
            if not isinstance(item, dict):
                fatal("Each array element in JSON config must be an object")
            item_id = item.get("id")
            if item_id is None:
                fatal("Element has no 'id' property.")
            exists = any(
                ids_equal(item_id, existing.get("id"))
                for existing in response
                if isinstance(existing, dict)
            )
            if exists:
                url = f"{api_path}/{item_id}"
                payload = json.dumps(item)
                debug(f"TRACE :: Updating existing element (id={item_id}) at {url}")
                debug(f"TRACE :: Payload: {payload}")
                arr_api_attempt("PUT", url, payload)
            else:
                payload = json.dumps({k: v for k, v in item.items() if k != "id"})
                debug(
                    "TRACE :: Resource id=%s not found; creating new entry via POST"
                    % item_id
                )
                debug(f"TRACE :: Payload: {payload}")
                arr_api_attempt("POST", api_path, payload)
    else:
        debug("Detected JSON object, sending single PUT...")
        payload = json.dumps(json_data)
        arr_api_attempt("PUT", api_path, payload)
