#!/bin/bash
set -euo pipefail

### Script values
scriptName="AutoConfig"

#### Import shared utilities
source /app/utilities.sh

### Preamble ###

log "INFO :: Starting ${scriptName}"

log "DEBUG :: AUTOCONFIG_MEDIA_MANAGEMENT=${AUTOCONFIG_MEDIA_MANAGEMENT}"
log "DEBUG :: AUTOCONFIG_MEDIA_MANAGEMENT_JSON=${AUTOCONFIG_MEDIA_MANAGEMENT_JSON}"
log "DEBUG :: AUTOCONFIG_METADATA_CONSUMER=${AUTOCONFIG_METADATA_CONSUMER}"
log "DEBUG :: AUTOCONFIG_METADATA_CONSUMER_JSON=${AUTOCONFIG_METADATA_CONSUMER_JSON}"
log "DEBUG :: AUTOCONFIG_METADATA_PROVIDER=${AUTOCONFIG_METADATA_PROVIDER}"
log "DEBUG :: AUTOCONFIG_METADATA_PROVIDER_JSON=${AUTOCONFIG_METADATA_PROVIDER_JSON}"
log "DEBUG :: AUTOCONFIG_LIDARR_UI=${AUTOCONFIG_LIDARR_UI}"
log "DEBUG :: AUTOCONFIG_LIDARR_UI_JSON=${AUTOCONFIG_LIDARR_UI_JSON}"
log "DEBUG :: AUTOCONFIG_METADATA_PROFILE=${AUTOCONFIG_METADATA_PROFILE}"
log "DEBUG :: AUTOCONFIG_METADATA_PROFILE_JSON=${AUTOCONFIG_METADATA_PROFILE_JSON}"
log "DEBUG :: AUTOCONFIG_TRACK_NAMING=${AUTOCONFIG_TRACK_NAMING}"
log "DEBUG :: AUTOCONFIG_TRACK_NAMING_JSON=${AUTOCONFIG_TRACK_NAMING_JSON}"

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
[ "${AUTOCONFIG_MEDIA_MANAGEMENT}" == "true" ] &&
    updateConfig "${AUTOCONFIG_MEDIA_MANAGEMENT_JSON}" "config/mediamanagement" "Media Management"

[ "${AUTOCONFIG_METADATA_CONSUMER}" == "true" ] &&
    updateConfig "${AUTOCONFIG_METADATA_CONSUMER_JSON}" "metadata" "Metadata Consumer"

[ "${AUTOCONFIG_METADATA_PROVIDER}" == "true" ] &&
    updateConfig "${AUTOCONFIG_METADATA_PROVIDER_JSON}" "config/metadataProvider" "Metadata Provider"

[ "${AUTOCONFIG_LIDARR_UI}" == "true" ] &&
    updateConfig "${AUTOCONFIG_LIDARR_UI_JSON}" "config/ui" "UI"

[ "${AUTOCONFIG_METADATA_PROFILE}" == "true" ] &&
    updateConfig "${AUTOCONFIG_METADATA_PROFILE_JSON}" "metadataprofile" "Metadata Profile"

[ "${AUTOCONFIG_TRACK_NAMING}" == "true" ] &&
    updateConfig "${AUTOCONFIG_TRACK_NAMING_JSON}" "config/naming" "Track Naming"

log "INFO :: Auto Configuration Complete"
exit 0
