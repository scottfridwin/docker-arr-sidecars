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
log "DEBUG :: AUTOCONFIG_MEDIAMANAGEMENT=${AUTOCONFIG_MEDIAMANAGEMENT}"
log "DEBUG :: AUTOCONFIG_MEDIAMANAGEMENT_JSON=${AUTOCONFIG_MEDIAMANAGEMENT_JSON}"
log "DEBUG :: AUTOCONFIG_METADATACONSUMER=${AUTOCONFIG_METADATACONSUMER}"
log "DEBUG :: AUTOCONFIG_METADATACONSUMER_JSON=${AUTOCONFIG_METADATACONSUMER_JSON}"
log "DEBUG :: AUTOCONFIG_METADATAPROVIDER=${AUTOCONFIG_METADATAPROVIDER}"
log "DEBUG :: AUTOCONFIG_METADATAPROVIDER_JSON=${AUTOCONFIG_METADATAPROVIDER_JSON}"
log "DEBUG :: AUTOCONFIG_UI=${AUTOCONFIG_UI}"
log "DEBUG :: AUTOCONFIG_UI_JSON=${AUTOCONFIG_UI_JSON}"
log "DEBUG :: AUTOCONFIG_METADATAPROFILE=${AUTOCONFIG_METADATAPROFILE}"
log "DEBUG :: AUTOCONFIG_METADATAPROFILE_JSON=${AUTOCONFIG_METADATAPROFILE_JSON}"
log "DEBUG :: AUTOCONFIG_NAMING=${AUTOCONFIG_NAMING}"
log "DEBUG :: AUTOCONFIG_NAMING_JSON=${AUTOCONFIG_NAMING_JSON}"

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
[ "${AUTOCONFIG_MEDIAMANAGEMENT}" == "true" ] &&
    updateArrConfig "${AUTOCONFIG_MEDIAMANAGEMENT_JSON}" "config/mediamanagement" "Media Management"

[ "${AUTOCONFIG_METADATACONSUMER}" == "true" ] &&
    updateArrConfig "${AUTOCONFIG_METADATACONSUMER_JSON}" "metadata" "Metadata Consumer"

[ "${AUTOCONFIG_METADATAPROVIDER}" == "true" ] &&
    updateArrConfig "${AUTOCONFIG_METADATAPROVIDER_JSON}" "config/metadataProvider" "Metadata Provider"

[ "${AUTOCONFIG_UI}" == "true" ] &&
    updateArrConfig "${AUTOCONFIG_UI_JSON}" "config/ui" "UI"

[ "${AUTOCONFIG_METADATAPROFILE}" == "true" ] &&
    updateArrConfig "${AUTOCONFIG_METADATAPROFILE_JSON}" "metadataprofile" "Metadata Profile"

[ "${AUTOCONFIG_NAMING}" == "true" ] &&
    updateArrConfig "${AUTOCONFIG_NAMING_JSON}" "config/naming" "Naming"

log "INFO :: Auto Configuration Complete"
exit 0
