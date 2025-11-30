#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
declare -A LOG_PRIORITY=(["TRACE"]=0 ["DEBUG"]=1 ["INFO"]=2 ["WARNING"]=3 ["ERROR"]=4)

# Logs messages with levels and respects LOG_LEVEL setting
log() {
    # $1 -> the log message, starting with level (TRACE, DEBUG, INFO, WARNING, ERROR)
    local msg="$1"

    # Ensure message starts with a valid level
    if [[ ! "$msg" =~ ^(TRACE|DEBUG|INFO|WARNING|ERROR) ]]; then
        echo "CRITICAL :: ${scriptName} :: Invalid log message format: '$msg'" >&2
        exit 1
    fi

    # Extract the level from the message
    local level="${msg%% *}" # first word

    # Compare priorities
    if ((LOG_PRIORITY[${level}] >= LOG_PRIORITY[${LOG_LEVEL}])); then
        echo "${scriptName} :: ${msg}" >&2
    fi
}

# Marks the container as healthy
setHealthy() {
    echo "healthy" >/tmp/health
}

# Marks the container as unhealthy and exits
setUnhealthy() {
    echo "unhealthy" >/tmp/health
    exit 1
}

# Validates essential environment variables
validateEnvironment() {
    log "TRACE :: Entering validateEnvironment..."
    [[ "${LOG_LEVEL}" =~ ^(TRACE|DEBUG|INFO|WARNING|ERROR)$ ]] || {
        echo "CRITICAL :: ${scriptName} :: Invalid LOG_LEVEL value: '${LOG_LEVEL}'. Must be one of: TRACE, DEBUG, INFO, WARNING, ERROR" >&2
        setUnhealthy
        exit 1
    }
    [[ -f "${ARR_CONFIG_PATH}" ]] || {
        log "ERROR :: File not found at '${ARR_CONFIG_PATH}'"
        setUnhealthy
        exit 1
    }
    if ! [[ "$UMASK" =~ ^[0-7]{3,4}$ ]]; then
        log "ERROR :: UMASK value '$UMASK' is invalid. Must be octal (e.g., 0022)"
        setUnhealthy
        exit 1
    fi
    log "TRACE :: Exiting validateEnvironment..."
}

# Retrieves the *arr API key from the config file
getArrApiKey() {
    log "TRACE :: Entering getArrApiKey..."

    local arrApiKey="$(get_state "arrApiKey")"

    if [[ -z "${arrApiKey}" ]]; then
        # Validate config file exists
        if [[ ! -f "${ARR_CONFIG_PATH}" ]]; then
            log "ERROR :: Config file not found: ${ARR_CONFIG_PATH}"
            setUnhealthy
            exit 1
        fi

        # Convert XML → JSON, then safely extract .Config.ApiKey
        arrApiKey="$(xq <"${ARR_CONFIG_PATH}" | safe_jq '.Config.ApiKey')"
        set_state "arrApiKey" "${arrApiKey}"
    fi

    log "TRACE :: Exiting getArrApiKey..."
}

# Constructs the *arr base URL from environment variables and config file
getArrUrl() {
    log "TRACE :: Entering getArrUrl..."
    local arrUrl="$(get_state "arrUrl")"
    if [[ -z "${arrUrl}" ]]; then
        # Validate config file exists
        if [[ ! -f "${ARR_CONFIG_PATH}" ]]; then
            log "ERROR :: Config file not found: ${ARR_CONFIG_PATH}"
            setUnhealthy
            exit 1
        fi

        # Extract URL base from config (optional)
        local arrUrlBase
        arrUrlBase="$(xq <"${ARR_CONFIG_PATH}" | safe_jq --optional '.Config.UrlBase')"
        if [[ "$arrUrlBase" == "null" || -z "$arrUrlBase" ]]; then
            arrUrlBase=""
        else
            arrUrlBase="/$(echo "$arrUrlBase" | sed 's#^/*##; s#/*$##')"
        fi

        # Extract port, preferring environment variable if set
        local arrPort="${ARR_PORT:-}"
        if [[ -z "$arrPort" || "$arrPort" == "null" ]]; then
            arrPort="$(xq <"${ARR_CONFIG_PATH}" | safe_jq '.Config.Port')"
        fi
        if [[ -z "$arrPort" || ! "$arrPort" =~ ^[0-9]+$ ]]; then
            log "ERROR :: Invalid or missing port value: '${arrPort}'"
            setUnhealthy
            exit 1
        fi

        # Construct final URL
        arrUrl="http://${ARR_HOST}:${arrPort}${arrUrlBase}"
        set_state "arrUrl" "${arrUrl}"
    fi
    log "TRACE :: Exiting getArrUrl..."
}

# Perform a *arr API request with error handling and retries
ArrApiRequest() {
    log "TRACE :: Entering ArrApiRequest..."
    # $1 = HTTP method (GET, POST, PUT, DELETE)
    # $2 = API path (e.g., config/mediamanagement)
    # $3 = Optional JSON payload
    local method="${1}"
    local path="${2}"
    local payload="${3:-}"
    local response body httpCode

    local arrUrl="$(get_state "arrUrl")"
    local arrApiKey="$(get_state "arrApiKey")"
    local arrApiVersion="$(get_state "arrApiVersion")"
    if [[ -z "$arrUrl" || -z "$arrApiKey" || -z "$arrApiVersion" ]]; then
        log "DEBUG :: Need to retrieve arr connection details in order to perform API requests"
        verifyArrApiAccess
    fi

    # If method is not GET, ensure *arr isn’t busy
    if [[ "${method}" != "GET" ]]; then
        ArrTaskStatusCheck
    fi

    if [[ -n "${payload}" ]]; then
        log "TRACE :: Executing ${ARR_NAME} Api call: method '${method}', url: '${arrUrl}/api/${arrApiVersion}/${path}', payload: ${payload}"
    else
        log "TRACE :: Executing ${ARR_NAME} Api call: method '${method}', url: '${arrUrl}/api/${arrApiVersion}/${path}'"
    fi

    while true; do
        if [[ -n "${payload}" ]]; then
            response=$(curl -s -w "\n%{http_code}" -X "${method}" \
                -H "X-Api-Key: ${arrApiKey}" \
                -H "Content-Type: application/json" \
                -d "${payload}" \
                "${arrUrl}/api/${arrApiVersion}/${path}")
        else
            response=$(curl -s -w "\n%{http_code}" -X "${method}" \
                -H "X-Api-Key: ${arrApiKey}" \
                "${arrUrl}/api/${arrApiVersion}/${path}")
        fi

        httpCode=$(tail -n1 <<<"${response}")
        body=$(sed '$d' <<<"${response}")

        set_state "arrApiReponseCode" "${httpCode}"
        set_state "arrApiResponse" "${body}"
        log "TRACE :: httpCode: ${httpCode}"
        log "TRACE :: body: ${body}"
        case "${httpCode}" in
        200 | 201 | 202 | 204)
            # Successful request
            break
            ;;
        000)
            # Connection failed — retry after waiting
            log "WARNING :: ${ARR_NAME} unreachable — entering recovery loop..."
            local statusResponse statusBody statusHttpCode
            while true; do
                sleep 5
                statusResponse=$(curl -s -w "\n%{http_code}" -X "GET" \
                    -H "X-Api-Key: ${arrApiKey}" \
                    "${arrUrl}/api/${arrApiVersion}/system/status")
                statusHttpCode=$(tail -n1 <<<"${statusResponse}")
                statusBody=$(sed '$d' <<<"${statusResponse}")
                log "DEBUG :: ${ARR_NAME} status request (${arrUrl}/api/${arrApiVersion}/system/status) returned ${statusHttpCode} with body ${statusBody}"
                if [[ "${httpCode}" -eq "200" ]]; then
                    log "DEBUG :: ${ARR_NAME} connectivity restored, retrying previous request..."
                    break
                fi
            done
            ;;
        *)
            # Any other HTTP error is fatal
            log "ERROR :: ${ARR_NAME} API call failed (HTTP ${httpCode}) for ${method} ${path}"
            setUnhealthy
            exit 1
            ;;
        esac
    done
    log "TRACE :: Exiting ArrApiRequest..."
}

# Checks *arr for any active tasks and waits for them to complete
ArrTaskStatusCheck() {
    log "TRACE :: Entering ArrTaskStatusCheck..."
    local alerted="no"
    local taskList taskCount

    while true; do
        # Fetch all commands from *arr
        ArrApiRequest "GET" "command"
        taskList="$(get_state "arrApiResponse")"

        # Ensure the response looks valid before parsing
        if [[ -z "${taskList}" || "${taskList}" == "null" ]]; then
            log "ERROR :: ${ARR_NAME} API returned empty or null response for command list"
            setUnhealthy
            exit 1
        fi

        # Count active tasks safely
        taskCount="$(safe_jq '[.[] | select(.status == "started") | .name] | length' <<<"${taskList}")"

        # Sanity check task count
        if ! [[ "${taskCount}" =~ ^[0-9]+$ ]]; then
            log "ERROR :: Invalid task count parsed from ${ARR_NAME} response: '${taskCount}'"
            setUnhealthy
            exit 1
        fi

        if ((taskCount >= 1)); then
            if [[ "${alerted}" == "no" ]]; then
                alerted="yes"
                log "INFO :: ${ARR_NAME} busy :: Waiting for ${taskCount} active ${ARR_NAME} tasks to complete..."
            fi
            sleep 2
        else
            break
        fi
    done
    log "TRACE :: Exiting ArrTaskStatusCheck..."
}

# Ensures connectivity to *arr and determines API version
verifyArrApiAccess() {
    log "TRACE :: Entering verifyArrApiAccess..."
    getArrApiKey
    getArrUrl

    local arrUrl="$(get_state "arrUrl")"
    local arrApiKey="$(get_state "arrApiKey")"
    if [ -z "$arrUrl" ] || [ -z "$arrApiKey" ]; then
        log "ERROR :: verifyArrApiAccess requires both URL and API key"
        setUnhealthy
        exit 1
    fi

    local apiTest=""
    local arrApiVersion=""
    local httpCode=""
    local body=""
    local curlExit=""

    # Normalize and split supported versions
    IFS=',' read -r -a supported_versions <<<"${ARR_SUPPORTED_API_VERSIONS// /}"

    for ver in "${supported_versions[@]}"; do
        local testUrl="${arrUrl}/api/${ver}/system/status?apikey=${arrApiKey}"
        log "DEBUG :: Attempting connection to \"${testUrl}\"..."

        # Recovery loop for connectivity failures (HTTP 000 or empty response)
        while true; do
            set +e
            apiTest="$(timeout 15 curl -s --connect-timeout 5 --max-time 10 -w "\n%{http_code}" "${testUrl}" 2>&1)"
            curlExit=$?
            set -e

            httpCode=$(tail -n1 <<<"${apiTest}")
            body=$(sed '$d' <<<"${apiTest}")

            if [[ "${curlExit}" -ne 0 ]]; then
                log "WARNING :: curl failed (exit ${curlExit}) — retrying in 5s..."
                sleep 5
                continue
            fi

            if [[ "${httpCode}" == "200" ]]; then
                # Safely extract instance name using your jq wrapper
                local instanceName
                instanceName="$(safe_jq '.instanceName' <<<"${body}")"

                arrApiVersion=${ver}
                log "DEBUG :: ${ARR_NAME} API ${ver} available (instance: ${instanceName})"
                break 2 # Found valid version; break out of both loops

            elif [[ "${httpCode}" == "000" ]]; then
                log "WARNING :: ${ARR_NAME} unreachable — retrying in 5s..."
                sleep 5
                continue

            else
                # Try next version, log what happened
                log "DEBUG :: ${ARR_NAME} returned HTTP ${httpCode} for v${ver}"
                if [[ -n "${body}" && "${body}" == *"error"* ]]; then
                    log "DEBUG :: API error response: $(echo "${body}" | head -c 300)"
                fi
                break
            fi
        done
    done

    if [[ -z "${arrApiVersion}" ]]; then
        log "ERROR :: Unable to connect to ${ARR_NAME} with any supported API versions. Supported: ${ARR_SUPPORTED_API_VERSIONS}"
        setUnhealthy
        exit 1
    fi

    set_state "arrApiVersion" "${arrApiVersion}"
    log "DEBUG :: ${ARR_NAME} API access verified (URL: ${arrUrl}, Version: ${arrApiVersion})"
    log "TRACE :: Exiting verifyArrApiAccess..."
}

# Compares API response to payload and logs mismatches
responseMatchesPayload() {
    local payload="$1"
    local response="$2"

    # Validate inputs
    if [[ -z "$payload" || -z "$response" ]]; then
        log "ERROR :: responseMatchesPayload called with empty payload or response"
        setUnhealthy
        exit 1
    fi

    # Sanity check: confirm both look like JSON before continuing
    if [[ "$payload" != *"{"* && "$payload" != *"["* ]]; then
        log "ERROR :: Payload is not valid JSON"
        setUnhealthy
        exit 1
    fi
    if [[ "$response" != *"{"* && "$response" != *"["* ]]; then
        log "ERROR :: Response is not valid JSON"
        setUnhealthy
        exit 1
    fi

    local mismatches
    if ! mismatches="$(jq -n \
        --slurpfile payload <(echo "$payload") \
        --slurpfile response <(echo "$response") '
        def compare_values($key; $pval; $rval):
          if $key == "fields" and ($pval | type) == "array" then
            reduce $pval[] as $item ([]; 
              if ($rval | map(select(.name == $item.name)) | length) == 0 then
                . + ["Missing field: " + $item.name]
              else
                . + ($rval
                  | map(select(.name == $item.name and .value != $item.value))
                  | map("Value mismatch in field " + $item.name
                        + " (expected: " + ($item.value|tostring)
                        + ", got: " + (.value|tostring) + ")"))
              end)
          elif ($pval | type) == "object" then
            reduce ($pval | to_entries[]) as $sub ([]; . + compare_values($sub.key; $sub.value; $rval[$sub.key]))
          elif ($pval != $rval) then
            ["Value mismatch: " + $key + " (expected: " + ($pval|tostring) + ", got: " + ($rval|tostring) + ")"]
          else
            []
          end;

        def compare_payload($p; $r):
          if ($p | type) == "object" then
            reduce ($p | to_entries[]) as $item ([]; . + compare_values($item.key; $item.value; $r[$item.key]))
          else
            []
          end;

        compare_payload($payload[0]; $response[0])
        ' 2> >(jq_error=$(cat)))"; then
        log "ERROR :: jq comparison failed inside responseMatchesPayload"
        [[ -n "${jq_error:-}" ]] && log "ERROR :: jq stderr: ${jq_error}"
        setUnhealthy
        exit 1
    fi

    # --- Process results ---
    if [[ -n "$mismatches" && "$mismatches" != "[]" ]]; then
        log "DEBUG :: Found differences between payload and response:"
        while IFS= read -r line; do
            log "DEBUG :: $line"
        done <<<"$mismatches"
        return 1
    fi

    return 0
}

# Attempts an API request multiple times until the response matches the payload
arrApiAttempt() {
    local method="$1"
    local url="$2"
    local payload="$3"
    local max_attempts=5
    local attempt=1
    local resp

    while true; do
        ArrApiRequest "$method" "$url" "$payload"
        resp="$(get_state "arrApiResponse")"

        # Validate JSON response using safe_jq
        safe_jq 'type' <<<"$resp" >/dev/null 2>&1

        if [[ -z "$resp" || "$resp" == "null" ]]; then
            if [[ "$method" == "PUT" ]]; then
                log "DEBUG :: Empty or invalid response to PUT; fetching $url to verify..."
                ArrApiRequest "GET" "$url"
                resp="$(get_state "arrApiResponse")"

                # Recheck JSON validity
                safe_jq -e 'type=="object" or type=="array"' <<<"$resp" || {
                    log "ERROR :: Invalid JSON received from GET $url during verification."
                    setUnhealthy
                    exit 1
                }
            else
                log "DEBUG :: Empty or invalid response to $method at $url; skipping verification for this attempt."
                break
            fi
        fi

        # Compare response to payload
        if responseMatchesPayload "$payload" "$resp"; then
            break
        fi

        if ((attempt >= max_attempts)); then
            log "ERROR :: ${ARR_NAME} response does not reflect requested changes for $url after $attempt attempts."
            setUnhealthy
            exit 1
        fi

        log "WARNING :: ${ARR_NAME} response mismatch for $url; retrying in 5s ($attempt/$max_attempts)..."
        sleep 5
        attempt=$((attempt + 1))
    done
}

# Updates *arr configuration via API from a JSON file
updateArrConfig() {
    log "TRACE :: Entering updateArrConfig..."
    local jsonFile="$1"
    local apiPath="$2"
    local settingName="$3"

    # Validate JSON file
    if [[ -z "$jsonFile" || ! -f "$jsonFile" ]]; then
        log "ERROR :: JSON config file not set or not found: $jsonFile"
        setUnhealthy
        exit 1
    fi

    log "DEBUG :: Configuring ${ARR_NAME} ${settingName} Settings"

    # Load JSON safely
    local jsonData
    jsonData="$(safe_jq '.' <"$jsonFile")"

    # Determine type (array or object)
    local jsonType
    jsonType="$(safe_jq 'if type=="array" then "array" else "object" end' <<<"$jsonData")"

    if [[ "$jsonType" == "array" ]]; then
        log "DEBUG :: Detected JSON array, sending one PUT/POST per element..."
        local length
        length="$(safe_jq 'length' <<<"$jsonData")"

        log "TRACE :: Fetching existing resources at $apiPath..."
        ArrApiRequest "GET" "$apiPath"
        local response
        response="$(get_state "arrApiResponse")"
        # Validate API response
        response="$(safe_jq '.' <<<"$response")"

        for ((i = 0; i < length; i++)); do
            local item id exists url payload

            item="$(safe_jq ".[$i]" <<<"$jsonData")"
            id="$(safe_jq -r ".[$i].id" <<<"$jsonData")"

            if [[ -z "$id" || "$id" == "null" ]]; then
                log "ERROR :: Element $((i + 1)) has no 'id' property."
                setUnhealthy
                exit 1
            fi

            exists="$(safe_jq --arg id "$id" 'map(select(.id == ($id|tonumber))) | length' <<<"$response")"

            if ((exists > 0)); then
                url="${apiPath}/${id}"
                payload="$item"
                log "TRACE :: Updating existing element (id=$id) at $url"
                log "TRACE :: Payload: $payload"
                arrApiAttempt "PUT" "$url" "$payload"
            else
                payload="$(safe_jq 'del(.id)' <<<"$item")"
                log "TRACE :: Resource id=$id not found; creating new entry via POST"
                log "TRACE :: Payload: $payload"
                arrApiAttempt "POST" "$apiPath" "$payload"
            fi
        done
    else
        log "DEBUG :: Detected JSON object, sending single PUT..."
        local payload="$jsonData"
        arrApiAttempt "PUT" "$apiPath" "$payload"
    fi

    log "TRACE :: Exiting updateArrConfig..."
}

# Normalizes a string for comparison
normalize_string() {
    # $1 -> the string to normalize

    # Converts smart quotes → plain quotes
    # Converts en dashes → hyphens
    # Converts non-breaking spaces → regular spaces
    # Collapses multiple spaces → one
    # Trims leading/trailing spaces
    # Removes parentheses
    # Removes ? characters
    # Removes ! characters
    # Removes commas
    # Removes colons
    # Replaces masculine ordinal º with degree symbol °
    # Replace & with "and"
    echo "$1" |
        sed -e "s/’/'/g" \
            -e "s/‘/'/g" \
            -e 's/“/"/g' \
            -e 's/”/"/g' \
            -e 's/–/-/g' \
            -e 's/º/°/g' \
            -e 's/&/and/g' \
            -e 's/\xA0/ /g' \
            -e 's/[[:space:]]\+/ /g' \
            -e 's/^ *//; s/ *$//' \
            -e 's/[()]//g' \
            -e 's/[?]//g' \
            -e 's/[!]//g' \
            -e 's/[,]//g' \
            -e 's/[:]//g'
}

# Removes quotes from a string
remove_quotes() {
    # $1 -> the string to process

    # Remove quotes
    echo "$1" | sed -e "s/['\"]//g"
}

# Safe jq wrapper that logs parse errors
safe_jq() {
    local optional=false
    local filter

    # Optional flag
    if [[ "$1" == "--optional" ]]; then
        optional=true
        shift
    fi

    filter="$1"
    shift # now "$@" contains jq extra args (--arg, --argjson, etc.)

    # Read stdin
    local input
    input="$(cat)"

    # Validate minimal JSON structure
    if [[ -z "$input" || ("$input" != *"{"* && "$input" != *"["*) ]]; then
        log "ERROR :: safe_jq received invalid JSON input"
        setUnhealthy
        exit 1
    fi

    # Run jq and forward extra arguments
    local result
    if ! result=$(jq -r "$filter" "$@" <<<"$input"); then
        log "ERROR :: jq command failed for filter: $filter"
        setUnhealthy
        exit 1
    fi

    # Optional: convert nulls to empty string
    if $optional; then
        result=$(awk '{if($0=="null") print ""; else print $0}' <<<"$result")
    else
        if [[ "$result" == "null" || -z "$result" ]]; then
            log "ERROR :: safe_jq extracted null or empty result for filter: $filter"
            setUnhealthy
            exit 1
        fi
    fi

    echo "$result"
}

# Cleans a string for safe use in file or folder names
CleanPathString() {
    local input="$1"

    # Remove leading/trailing whitespace
    input="$(echo "$input" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

    # Replace invalid filename characters with underscores
    # Invalid: / \ : * ? " < > |
    input="${input//\//_}"
    input="${input//\\/_}"
    input="${input//:/_}"
    input="${input//\*/_}"
    input="${input//\?/_}"
    input="${input//</_}"
    input="${input//>/_}"
    input="${input//|/_}"

    # Remove hyphens (-) to better support path parsing
    input="${input//-/}"

    # Remove remaining quotes (single or double)
    input="${input//\'/}"
    input="${input//\"/}"

    # Replace consecutive spaces with a single underscore
    input="$(echo "$input" | tr -s ' ' '_')"

    # Optionally limit the length (safe for most filesystems)
    echo "${input:0:150}"
}

# Create a named associative array: auto-named using shell PID
init_state() {
    local name=$(_get_state_name)

    # Check if the variable already exists
    if declare -p "$name" &>/dev/null; then
        log "ERROR :: State object '$name' already exists."
        setUnhealthy
        exit 1
    fi

    # Create the global associative array
    eval "declare -gA ${name}=()"
}

reset_state() {
    local name=$(_get_state_name)

    # Check if the state object exists
    if ! declare -p "$name" &>/dev/null; then
        log "ERROR :: State object '$name' not found for reset."
        setUnhealthy
        exit 1
    fi

    # Clear the associative array
    eval "$name=()"
}

# Internal helper to resolve current state object name
_get_state_name() {
    echo "state_$$"
}

# Generic setter: set_state <key> <value>
set_state() {
    local name=$(_get_state_name)
    local -n obj="$name"
    local key="$1"
    local value="$2"
    obj["$key"]="$value"
}

# Generic getter: get_state <key>
get_state() {
    local key="$1"
    local name=$(_get_state_name)

    # Check if the state object exists
    if ! declare -p "$name" &>/dev/null; then
        log "ERROR :: State object '$name' not found for reset."
        setUnhealthy
        exit 1
    fi

    local -n obj="$name"

    # Protect against unbound key under `set -u`
    if [[ ! -v "obj[$key]" ]]; then
        echo "" # or handle error
        return 0
    fi

    local -n obj="$name"
    echo "${obj[$key]}"
}
