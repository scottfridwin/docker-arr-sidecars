#!/bin/bash
set -euo pipefail

### Script values
scriptName="ARLChecker"

#### Import Functions
source /app/functions.bash

### Preamble ###

log "INFO :: Starting ${scriptName} version"

log "DEBUG :: ARLUPDATE_INTERVAL=${ARLUPDATE_INTERVAL}"
log "DEBUG :: AUDIO_DEEMIX_ARL_FILE=${AUDIO_DEEMIX_ARL_FILE}"

### Validation ###

if ! [[ "$ARLUPDATE_INTERVAL" =~ ^[0-9]+[smhd]$ ]]; then
    log "ERROR :: ARLUPDATE_INTERVAL is invalid (must be <number>[s|m|h|d])"
    setUnhealthy
    exit 1
fi
if [[ ! -f "${AUDIO_DEEMIX_ARL_FILE}" ]]; then
    log "ERROR :: ARL file not found at '${AUDIO_DEEMIX_ARL_FILE}'"
    setUnhealthy
    exit 1
fi

# Check ownership and permissions
file_owner_uid=$(stat -c "%u" "${AUDIO_DEEMIX_ARL_FILE}")
current_uid=$(id -u)
file_perms=$(stat -c "%a" "${AUDIO_DEEMIX_ARL_FILE}")

if [[ "${file_owner_uid}" -ne "${current_uid}" ]]; then
    log "ERROR :: ARL file '${AUDIO_DEEMIX_ARL_FILE}' is not owned by the current user (uid ${current_uid})"
    setUnhealthy
    exit 1
fi

if [[ "${file_perms}" != "600" ]]; then
    log "ERROR :: ARL file '${AUDIO_DEEMIX_ARL_FILE}' has incorrect permissions (${file_perms}). Expected 600."
    setUnhealthy
    exit 1
fi

### Main ###

while true; do
    log "INFO :: Running ARL Token Check..."
    if ! python python/ARLChecker.py -c; then
        log "ERROR :: ARL token check failed — see Python logs for details"
        setUnhealthy
        exit 1
    fi

    log "INFO :: ARL Token Check Complete. Sleeping for ${ARLUPDATE_INTERVAL}."
    sleep "${ARLUPDATE_INTERVAL}"
done
