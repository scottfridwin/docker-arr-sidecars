#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
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

# Initalize state object
init_state

# Verify API access
verifyArrApiAccess

# Conditionally update each setting
[ "${AUTOCONFIG_MEDIA_MANAGEMENT}" == "true" ] &&
    updateArrConfig "${AUTOCONFIG_MEDIA_MANAGEMENT_JSON}" "config/mediamanagement" "Media Management"

[ "${AUTOCONFIG_METADATA_CONSUMER}" == "true" ] &&
    updateArrConfig "${AUTOCONFIG_METADATA_CONSUMER_JSON}" "metadata" "Metadata Consumer"

[ "${AUTOCONFIG_METADATA_PROVIDER}" == "true" ] &&
    updateArrConfig "${AUTOCONFIG_METADATA_PROVIDER_JSON}" "config/metadataProvider" "Metadata Provider"

[ "${AUTOCONFIG_LIDARR_UI}" == "true" ] &&
    updateArrConfig "${AUTOCONFIG_LIDARR_UI_JSON}" "config/ui" "UI"

[ "${AUTOCONFIG_METADATA_PROFILE}" == "true" ] &&
    updateArrConfig "${AUTOCONFIG_METADATA_PROFILE_JSON}" "metadataprofile" "Metadata Profile"

[ "${AUTOCONFIG_TRACK_NAMING}" == "true" ] &&
    updateArrConfig "${AUTOCONFIG_TRACK_NAMING_JSON}" "config/naming" "Track Naming"

log "INFO :: Auto Configuration Complete"
exit 0
