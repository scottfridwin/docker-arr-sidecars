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
    log "TRACE :: Exiting validateEnvironment..."
}

# Retrieves the *arr API key from the config file
getArrApiKey() {
    log "TRACE :: Entering getArrApiKey..."
    local arrApiKey="$(get_state "arrApiKey")"
    if [[ -z "${arrApiKey}" ]]; then
        arrApiKey="$(cat "${ARR_CONFIG_PATH}" | xq | jq -r .Config.ApiKey)"
        if [ -z "$arrApiKey" ] || [ "$arrApiKey" == "null" ]; then
            log "ERROR :: Unable to retrieve ${ARR_NAME} API key from configuration file: $ARR_CONFIG_PATH"
            setUnhealthy
            exit 1
        fi
        set_state "arrApiKey" "${arrApiKey}"
    fi
    log "TRACE :: Exiting getArrApiKey..."
}

# Constructs the *arr base URL from environment variables and config file
getArrUrl() {
    log "TRACE :: Entering getArrUrl..."
    local arrUrl="$(get_state "arrUrl")"
    if [[ -z "${arrUrl}" ]]; then
        # Get *arr base URL. Usually blank, but can be set in *arr settings.
        local arrUrlBase="$(cat "${ARR_CONFIG_PATH}" | xq | jq -r .Config.UrlBase)"
        if [ "$arrUrlBase" == "null" ]; then
            arrUrlBase=""
        else
            arrUrlBase="/$(echo "$arrUrlBase" | sed "s/\///")"
        fi

        # If an external port is provided, use it. Otherwise, get the port from the config file.
        local arrPort="${ARR_PORT}"
        if [ -z "$arrPort" ] || [ "$arrPort" == "null" ]; then
            arrPort="$(cat "${ARR_CONFIG_PATH}" | xq | jq -r .Config.Port)"
        fi

        # Construct and return the full URL
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
        log "INFO :: Need to retrieve arr connection details in order to perform API requests"
        verifyArrApiAccess
    fi

    # If method is not GET, ensure *arr isn’t busy
    if [[ "${method}" != "GET" ]]; then
        ArrTaskStatusCheck
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
                    log "INFO :: ${ARR_NAME} connectivity restored, retrying previous request..."
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

        # Count active tasks
        taskCount=$(jq -r '.[] | select(.status=="started") | .name' <<<"${taskList}" | wc -l)

        if ((taskCount >= 1)); then
            if [[ "${alerted}" == "no" ]]; then
                alerted="yes"
                log "INFO :: ${ARR_NAME} busy :: Pausing/waiting for all active ${ARR_NAME} tasks to end..."
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

    # Normalize by removing spaces and splitting on commas
    IFS=',' read -r -a supported_versions <<<"${ARR_SUPPORTED_API_VERSIONS// /}"

    # Check if arrApiVersion is in the supported list
    for ver in "${supported_versions[@]}"; do
        log "DEBUG :: Attemping connection to \"${arrUrl}/api/${ver}/system/status\"..."
        apiTest="$(curl -s "${arrUrl}/api/${ver}/system/status?apikey=${arrApiKey}" | jq -r .instanceName)"
        if [ -n "${apiTest}" ]; then
            arrApiVersion=${ver}
            break
        fi
    done

    if [[ -z "${arrApiVersion}" ]]; then
        log "ERROR :: Unable to connect to ${ARR_NAME} with any supported API versions. Supported versions: ${ARR_SUPPORTED_API_VERSIONS}"
        setUnhealthy
        exit 1
    fi
    set_state "arrApiVersion" "${arrApiVersion}"

    log "INFO :: ${ARR_NAME} API access verified (URL: ${arrUrl}, API Version: ${arrApiVersion})"
    log "TRACE :: Exiting verifyArrApiAccess..."
}

updateArrConfig() {
    log "TRACE :: Entering updateConfig..."
    local jsonFile="${1}"
    local apiPath="${2}"
    local settingName="${3}"

    if [ -z "${jsonFile}" ] || [ ! -f "${jsonFile}" ]; then
        log "ERROR :: JSON config file not set or not found: ${jsonFile}"
        setUnhealthy
        exit 1
    fi

    log "INFO :: Configuring ${ARR_NAME} ${settingName} Settings"

    # Load JSON file
    local jsonData
    jsonData=$(<"${jsonFile}")

    # Determine whether it's an array or an object
    local jsonType
    jsonType=$(jq -r 'if type=="array" then "array" else "object" end' <<<"${jsonData}")

    if [[ "${jsonType}" == "array" ]]; then
        log "DEBUG :: Detected JSON array, sending one PUT per element..."
        local length
        length=$(jq 'length' <<<"${jsonData}")

        log "TRACE :: Getting existing resources at ${apiPath}"
        ArrApiRequest "GET" "${apiPath}"
        local response="$(get_state "arrApiResponse")"

        for ((i = 0; i < length; i++)); do
            local id item exists
            item=$(jq -c ".[$i]" <<<"${jsonData}")
            id=$(jq -r ".[$i].id" <<<"${jsonData}")

            if [[ -z "${id}" || "${id}" == "null" ]]; then
                log "ERROR :: Element $((i + 1)) has no 'id' property."
                setUnhealthy
                exit 1
            fi

            exists=$(jq --arg id "$id" 'map(select(.id == ($id|tonumber))) | length' <<<"${response}")
            if ((exists > 0)); then
                local url="${apiPath}/${id}"
                log "TRACE :: Updating existing element (id=${id}) at ${url}"
                ArrApiRequest "PUT" "${url}" "${item}"
            else
                payload=$(jq 'del(.id)' <<<"${item}")
                log "TRACE :: Resource id=${id} not found; creating new entry via POST"
                ArrApiRequest "POST" "${apiPath}" "${payload}"
            fi
        done
    else
        log "DEBUG :: Detected JSON object, sending single PUT..."
        ArrApiRequest "PUT" "${apiPath}" "${jsonData}"
    fi

    # Read the JSON file and send it via ArrApiRequest
    local jsonData
    jsonData=$(<"${jsonFile}") # load JSON into a variable

    ArrApiRequest "PUT" "${apiPath}" "${jsonData}"
    log "INFO :: Successfully updated ${ARR_NAME} ${settingName}"

    log "TRACE :: Exiting updateConfig..."
}

# Normalizes a string by replacing smart quotes and normalizing spaces
normalize_string() {
    # $1 -> the string to normalize

    # Converts smart quotes → plain quotes
    # Converts en dashes → hyphens
    # Converts non-breaking spaces → regular spaces
    # Collapses multiple spaces → one
    # Trims leading/trailing spaces
    # Removes parentheses
    echo "$1" |
        sed -e "s/’/'/g" \
            -e "s/‘/'/g" \
            -e 's/“/"/g' \
            -e 's/”/"/g' \
            -e 's/–/-/g' \
            -e 's/\xA0/ /g' \
            -e 's/[[:space:]]\+/ /g' \
            -e 's/^ *//; s/ *$//' \
            -e 's/[()]//g'
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
        echo "Error: State object '$name' not found" >&2
        return 1
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
