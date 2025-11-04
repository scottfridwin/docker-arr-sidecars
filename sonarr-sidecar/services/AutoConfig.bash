#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail

### Script values
scriptName="AutoConfig"

#### Import shared utilities
source /app/utilities.sh

### Preamble ###

log "INFO :: Starting ${scriptName}"

log "DEBUG :: AUTOCONFIG_DELAY=${AUTOCONFIG_DELAY}"
log "DEBUG :: AUTOCONFIG_CUSTOMFORMAT=${AUTOCONFIG_CUSTOMFORMAT}"
log "DEBUG :: AUTOCONFIG_CUSTOMFORMAT_JSON=${AUTOCONFIG_CUSTOMFORMAT_JSON}"
log "DEBUG :: AUTOCONFIG_DOWNLOADCLIENT=${AUTOCONFIG_DOWNLOADCLIENT}"
log "DEBUG :: AUTOCONFIG_DOWNLOADCLIENT_JSON=${AUTOCONFIG_DOWNLOADCLIENT_JSON}"
log "DEBUG :: AUTOCONFIG_HOST=${AUTOCONFIG_HOST}"
log "DEBUG :: AUTOCONFIG_HOST_JSON=${AUTOCONFIG_HOST_JSON}"
log "DEBUG :: AUTOCONFIG_MEDIAMANAGEMENT=${AUTOCONFIG_MEDIAMANAGEMENT}"
log "DEBUG :: AUTOCONFIG_MEDIAMANAGEMENT_JSON=${AUTOCONFIG_MEDIAMANAGEMENT_JSON}"
log "DEBUG :: AUTOCONFIG_NAMING=${AUTOCONFIG_NAMING}"
log "DEBUG :: AUTOCONFIG_NAMING_JSON=${AUTOCONFIG_NAMING_JSON}"
log "DEBUG :: AUTOCONFIG_QUALITYPROFILE=${AUTOCONFIG_QUALITYPROFILE}"
log "DEBUG :: AUTOCONFIG_QUALITYPROFILE_JSON=${AUTOCONFIG_QUALITYPROFILE_JSON}"
log "DEBUG :: AUTOCONFIG_REMOTEPATHMAPPING=${AUTOCONFIG_REMOTEPATHMAPPING}"
log "DEBUG :: AUTOCONFIG_REMOTEPATHMAPPING_JSON=${AUTOCONFIG_REMOTEPATHMAPPING_JSON}"
log "DEBUG :: AUTOCONFIG_UI=${AUTOCONFIG_UI}"
log "DEBUG :: AUTOCONFIG_UI_JSON=${AUTOCONFIG_UI_JSON}"

### Validation ###

# Nothing to validate

### Main ###

# Initial delay
if [ "${AUTOCONFIG_DELAY}" -gt 0 ]; then
    log "INFO :: Delaying for ${AUTOCONFIG_DELAY} seconds to allow ${ARR_NAME} to fully initialize database"
    sleep "${AUTOCONFIG_DELAY}"
fi

# Initalize state object
init_state

# Verify API access
verifyArrApiAccess

# Conditionally update each setting
[ "${AUTOCONFIG_CUSTOMFORMAT}" == "true" ] &&
    updateArrConfig "${AUTOCONFIG_CUSTOMFORMAT_JSON}" "customformat" "Custom Format(s)"

[ "${AUTOCONFIG_DOWNLOADCLIENT}" == "true" ] &&
    updateArrConfig "${AUTOCONFIG_DOWNLOADCLIENT_JSON}" "downloadclient" "Download Client"

[ "${AUTOCONFIG_HOST}" == "true" ] &&
    updateArrConfig "${AUTOCONFIG_HOST_JSON}" "config/host" "Host"

[ "${AUTOCONFIG_MEDIAMANAGEMENT}" == "true" ] &&
    updateArrConfig "${AUTOCONFIG_MEDIAMANAGEMENT_JSON}" "config/mediamanagement" "Media Management"

[ "${AUTOCONFIG_NAMING}" == "true" ] &&
    updateArrConfig "${AUTOCONFIG_NAMING_JSON}" "config/naming" "Naming"

[ "${AUTOCONFIG_QUALITYPROFILE}" == "true" ] &&
    updateArrConfig "${AUTOCONFIG_QUALITYPROFILE_JSON}" "qualityprofile" "Quality Profile(s)"

[ "${AUTOCONFIG_REMOTEPATHMAPPING}" == "true" ] &&
    updateArrConfig "${AUTOCONFIG_REMOTEPATHMAPPING_JSON}" "remotepathmapping" "Remote Path Mapping"

[ "${AUTOCONFIG_UI}" == "true" ] &&
    updateArrConfig "${AUTOCONFIG_UI_JSON}" "config/ui" "UI"

log "INFO :: Auto Configuration Complete"
exit 0
