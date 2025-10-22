#!/bin/bash
set -euo pipefail

### Script values
scriptName="AutoConfig"

#### Import Functions
source /app/functions.bash

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

updateLidarrConfig() {
    log "TRACE :: Entering updateLidarrConfig..."
    local jsonFile="${1}"
    local apiPath="${2}"
    local settingName="${3}"

    if [ -z "${jsonFile}" ] || [ ! -f "${jsonFile}" ]; then
        log "ERROR :: JSON config file not set or not found: ${jsonFile}"
        setUnhealthy
        exit 1
    fi

    log "INFO :: Configuring ${ARR_NAME} ${settingName} Settings"

    # Read the JSON file and send it via ArrApiRequest
    local jsonData
    jsonData=$(<"${jsonFile}") # load JSON into a variable

    ArrApiRequest "PUT" "${apiPath}" "${jsonData}"
    log "INFO :: Successfully updated ${ARR_NAME} ${settingName}"

    log "TRACE :: Exiting updateLidarrConfig..."
}

# Initalize state object
init_state

# Verify API access
verifyArrApiAccess

# Conditionally update each setting
[ "${AUTOCONFIG_MEDIA_MANAGEMENT}" == "true" ] &&
    updateLidarrConfig "${AUTOCONFIG_MEDIA_MANAGEMENT_JSON}" "config/mediamanagement" "Media Management"

[ "${AUTOCONFIG_METADATA_CONSUMER}" == "true" ] &&
    updateLidarrConfig "${AUTOCONFIG_METADATA_CONSUMER_JSON}" "metadata/1" "Metadata Consumer"

[ "${AUTOCONFIG_METADATA_PROVIDER}" == "true" ] &&
    updateLidarrConfig "${AUTOCONFIG_METADATA_PROVIDER_JSON}" "config/metadataProvider" "Metadata Provider"

[ "${AUTOCONFIG_LIDARR_UI}" == "true" ] &&
    updateLidarrConfig "${AUTOCONFIG_LIDARR_UI_JSON}" "config/ui" "UI"

[ "${AUTOCONFIG_METADATA_PROFILE}" == "true" ] &&
    updateLidarrConfig "${AUTOCONFIG_METADATA_PROFILE_JSON}" "metadataprofile/1" "Metadata Profile"

[ "${AUTOCONFIG_TRACK_NAMING}" == "true" ] &&
    updateLidarrConfig "${AUTOCONFIG_TRACK_NAMING_JSON}" "config/naming" "Track Naming"

log "INFO :: Auto Configuration Complete"
exit 0
