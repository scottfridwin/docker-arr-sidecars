#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail

### Script values
scriptName="AutoConfig"

#### Import shared utilities
source /app/utilities.sh

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

# Initalize state object
init_state

# Verify API access
verifyArrApiAccess

# Conditionally update each setting
[ "${AUTOCONFIG_MEDIAMANAGEMENT}" == "true" ] &&
    updateArrConfig "${AUTOCONFIG_MEDIAMANAGEMENT_JSON}" "config/mediamanagement" "Media Management"

[ "${AUTOCONFIG_HOST}" == "true" ] &&
    updateArrConfig "${AUTOCONFIG_HOST_JSON}" "config/host" "Host"

[ "${AUTOCONFIG_CUSTOMFORMAT}" == "true" ] &&
    updateArrConfig "${AUTOCONFIG_CUSTOMFORMAT_JSON}" "customformat" "Custom Format(s)"

[ "${AUTOCONFIG_UI}" == "true" ] &&
    updateArrConfig "${AUTOCONFIG_UI_JSON}" "config/ui" "UI"

[ "${AUTOCONFIG_QUALITYPROFILE}" == "true" ] &&
    updateArrConfig "${AUTOCONFIG_QUALITYPROFILE_JSON}" "qualityprofile" "Quality Profile(s)"

[ "${AUTOCONFIG_NAMING}" == "true" ] &&
    updateArrConfig "${AUTOCONFIG_NAMING_JSON}" "config/naming" "Naming"

log "INFO :: Auto Configuration Complete"
exit 0
