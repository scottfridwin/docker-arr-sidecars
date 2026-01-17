#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail

### Script values
scriptName="entrypoint"

#### Imports
source /app/utilities.sh

# Apply timezone from TZ environment variable (if provided)
if [[ -n "${TZ:-}" ]]; then
    if [[ -f "/usr/share/zoneinfo/${TZ}" ]]; then
        if [ -w /etc/localtime ]; then
            ln -sf "/usr/share/zoneinfo/${TZ}" /etc/localtime
            echo "${TZ}" >/etc/timezone 2>/dev/null || true
            log "INFO :: Timezone set to ${TZ}"
        else
            log "INFO :: /etc/localtime is not writable; skipping symlink (assuming host bind-mount)"
        fi
    else
        log "WARNING :: TZ='${TZ}' not found in /usr/share/zoneinfo"
    fi
fi

# Start with healthy status
setHealthy

### Preamble ###

log "INFO :: Starting ${scriptName}"

log "DEBUG :: UMASK=${UMASK}"
log "DEBUG :: ARR_NAME=${ARR_NAME}"
log "DEBUG :: ARR_CONFIG_PATH=${ARR_CONFIG_PATH}"
log "DEBUG :: ARR_SUPPORTED_API_VERSIONS=${ARR_SUPPORTED_API_VERSIONS}"
log "DEBUG :: LOG_LEVEL=${LOG_LEVEL}"
log "DEBUG :: ARR_HOST=${ARR_HOST}"
log "DEBUG :: ARR_PORT=${ARR_PORT}"

### Validation ###

# Validate environment variables
validateEnvironment

### Main ###

umask "$UMASK"
# Run all services
for script in /app/services/*.bash; do
    bash "$script" &
done
wait

# If we reach here, all of the services have exited
# This means something went wrong
# The container should be marked as unhealthy
setUnhealthy
