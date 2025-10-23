#!/bin/bash
set -euo pipefail

### Script values
scriptName="entrypoint"

#### Import shared utilities
source /app/utilities.sh

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
