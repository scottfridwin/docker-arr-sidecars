#!/bin/bash
set -euo pipefail

### Script values
scriptName="AutoConfig"

#### Import Functions
source /app/functions.bash

### Preamble ###

log "INFO :: Starting ${scriptName}"

log "DEBUG :: AUTOCONFIG_MEDIAMANAGEMENT=${AUTOCONFIG_MEDIAMANAGEMENT}"
log "DEBUG :: AUTOCONFIG_MEDIAMANAGEMENT_JSON=${AUTOCONFIG_MEDIAMANAGEMENT_JSON}"
log "DEBUG :: AUTOCONFIG_HOST=${AUTOCONFIG_HOST}"
log "DEBUG :: AUTOCONFIG_HOST_JSON=${AUTOCONFIG_HOST_JSON}"
log "DEBUG :: AUTOCONFIG_CUSTOMFORMAT=${AUTOCONFIG_CUSTOMFORMAT}"
log "DEBUG :: AUTOCONFIG_CUSTOMFORMAT_JSON=${AUTOCONFIG_CUSTOMFORMAT_JSON}"
log "DEBUG :: AUTOCONFIG_UI=${AUTOCONFIG_UI}"
log "DEBUG :: AUTOCONFIG_UI_JSON=${AUTOCONFIG_UI_JSON}"
log "DEBUG :: AUTOCONFIG_QUALITYPROFILE=${AUTOCONFIG_QUALITYPROFILE}"
log "DEBUG :: AUTOCONFIG_QUALITYPROFILE_JSON=${AUTOCONFIG_QUALITYPROFILE_JSON}"
log "DEBUG :: AUTOCONFIG_NAMING=${AUTOCONFIG_NAMING}"
log "DEBUG :: AUTOCONFIG_NAMING_JSON=${AUTOCONFIG_NAMING_JSON}"

### Validation ###

# Nothing to validate

### Main ###

updateConfig() {
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

        for ((i = 0; i < length; i++)); do
            local id item
            item=$(jq -c ".[$i]" <<<"${jsonData}")
            id=$(jq -r ".[$i].id" <<<"${jsonData}")

            if [[ -z "${id}" || "${id}" == "null" ]]; then
                log "ERROR :: Element $((i + 1)) has no 'id' property."
                setUnhealthy
                exit 1
            fi

            local url="${apiPath}/${id}"
            log "TRACE :: Sending element $((i + 1))/${length} to ${url}"
            ArrApiRequest "PUT" "${url}" "${item}"
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

# Initalize state object
init_state

# Verify API access
verifyArrApiAccess

# Conditionally update each setting
[ "${AUTOCONFIG_MEDIAMANAGEMENT}" == "true" ] &&
    updateConfig "${AUTOCONFIG_MEDIAMANAGEMENT_JSON}" "config/mediamanagement" "Media Management"

[ "${AUTOCONFIG_HOST}" == "true" ] &&
    updateConfig "${AUTOCONFIG_HOST_JSON}" "config/host" "Host"

[ "${AUTOCONFIG_CUSTOMFORMAT}" == "true" ] &&
    updateConfig "${AUTOCONFIG_CUSTOMFORMAT_JSON}" "customformat" "Custom Format(s)"

[ "${AUTOCONFIG_UI}" == "true" ] &&
    updateConfig "${AUTOCONFIG_UI_JSON}" "config/ui" "UI"

[ "${AUTOCONFIG_QUALITYPROFILE}" == "true" ] &&
    updateConfig "${AUTOCONFIG_QUALITYPROFILE_JSON}" "qualityprofile" "Quality Profile(s)"

[ "${AUTOCONFIG_NAMING}" == "true" ] &&
    updateConfig "${AUTOCONFIG_NAMING_JSON}" "config/naming" "Naming"

log "INFO :: Auto Configuration Complete"
exit 0
