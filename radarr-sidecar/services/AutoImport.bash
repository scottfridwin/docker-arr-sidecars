#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail

### Script values
scriptName="AutoImport"

#### Imports
source /app/utilities.sh

#### Constants

# Add custom download client if it doesn't already exist
AddDownloadClient() {
    log "TRACE :: Entering AddDownloadClient..."
    local downloadClientsData downloadClientCheck httpCode

    # Get list of existing download clients
    ArrApiRequest "GET" "downloadclient"
    downloadClientsData="$(get_state "arrApiResponse")"

    # Validate JSON response
    downloadClientsData="$(safe_jq '.' <<<"${downloadClientsData}")"

    # Check if our custom client already exists
    downloadClientExists="$(safe_jq --arg name "${AUTOIMPORT_DOWNLOADCLIENT_NAME}" '
        any(.[]; .name == $name)
    ' <<<"${downloadClientsData}")"

    if [[ "${downloadClientExists}" != "true" ]]; then
        log "INFO :: ${AUTOIMPORT_DOWNLOADCLIENT_NAME} client not found, creating it..."

        # Build JSON payload safely
        payload="$(
            jq -n \
                --arg name "${AUTOIMPORT_DOWNLOADCLIENT_NAME}" \
                --arg path "${AUTOIMPORT_SHARED_PATH}" \
                '{
                enable: true,
                protocol: "usenet",
                priority: 10,
                removeCompletedDownloads: true,
                removeFailedDownloads: true,
                name: $name,
                fields: [
                    {name: "nzbFolder", value: $path},
                    {name: "watchFolder", value: $path}
                ],
                implementationName: "Usenet Blackhole",
                implementation: "UsenetBlackhole",
                configContract: "UsenetBlackholeSettings",
                infoLink: "https://wiki.servarr.com/lidarr/supported#usenetblackhole",
                tags: []
            }'
        )"

        # Submit to API
        ArrApiRequest "POST" "downloadclient" "${payload}"
        log "INFO :: Successfully added ${AUTOIMPORT_DOWNLOADCLIENT_NAME} download client."
    else
        log "INFO :: ${AUTOIMPORT_DOWNLOADCLIENT_NAME} download client already exists, skipping creation."
    fi

    log "TRACE :: Exiting AddDownloadClient..."
}

# Gets the list of movies in the Radarr database and caches it to a file
GetMovies() {
    log "TRACE :: Entering GetMovies..."

    local moviesPathsCacheFile="${AUTOIMPORT_WORK_DIR}/moviepaths"
    local cacheAgeSeconds=$((AUTOIMPORT_CACHE_HOURS * 3600))
    local refreshNeeded=false

    # If cache missing, mark for refresh
    if [[ ! -f "${moviesPathsCacheFile}" ]]; then
        log "DEBUG :: Movie cache not found, will refresh..."
        refreshNeeded=true
    else
        local currentTime fileModTime age
        currentTime=$(date +%s)
        fileModTime=$(stat -c %Y "${moviesPathsCacheFile}" 2>/dev/null || echo 0)
        age=$((currentTime - fileModTime))

        if ((age > cacheAgeSeconds)); then
            log "DEBUG :: Movie cache older than ${AUTOIMPORT_CACHE_HOURS}h, refreshing..."
            refreshNeeded=true
        fi
    fi

    if [[ "${refreshNeeded}" == true ]]; then
        # Fetch movies from API
        ArrApiRequest "GET" "movie"
        local response
        response="$(get_state "arrApiResponse")"

        if [[ -z "${response}" || "${response}" == "null" ]]; then
            log "ERROR :: Failed to fetch movie list from ${ARR_NAME} API"
            setUnhealthy
            exit 1
        fi

        # Extract movie paths safely using safe_jq
        local moviePaths
        moviePaths="$(safe_jq -r '.[].path' <<<"${response}")"

        # Write cache atomically
        echo "${moviePaths}" >"${moviesPathsCacheFile}.tmp" && mv "${moviesPathsCacheFile}.tmp" "${moviesPathsCacheFile}"

        log "INFO :: Movie cache refreshed with $(wc -l <"${moviesPathsCacheFile}") entries"
    fi

    # Load cache contents into memory and store in state
    local moviePaths
    if [[ -f "${moviesPathsCacheFile}" ]]; then
        moviePaths="$(<"${moviesPathsCacheFile}")"
        set_state "moviePaths" "${moviePaths}"
    else
        log "ERROR :: Movie cache file missing after refresh attempt"
        setUnhealthy
        exit 1
    fi

    log "TRACE :: Exiting GetMovies..."
}

# Notify *arr to import the specified path
NotifyArrForImport() {
    log "TRACE :: Entering NotifyArrForImport..."
    # $1 -> folder path containing audio files for *arr to import
    local importPath="${1}"

    # Remove the import status file if it exists
    rm -rf "${importPath}/IMPORT_STATUS.txt"

    ArrApiRequest "POST" "command" "{\"name\":\"DownloadedMoviesScan\", \"path\":\"${importPath}\"}"

    log "INFO :: Sent notification to ${ARR_NAME} to import from path: ${importPath}"
    log "TRACE :: Exiting NotifyArrForImport..."
}

# Checks the permissions of the provided directory against expected permissions
CheckPermissions() {
    log "TRACE :: Entering CheckPermissions..."
    local path="${1}"
    local bad_files=()
    local report=""

    while IFS= read -r item; do
        # Skip symlinks
        [[ -L "${item}" ]] && continue

        local perms group
        perms=$(stat -c "%A" "${item}" 2>/dev/null || echo "----------")
        group=$(stat -c "%g" "${item}" 2>/dev/null || echo "0")

        local group_perms="${perms:4:3}" # characters 5-7 (group perms)
        local issue=""

        # Check correct group if defined
        if [[ "${group}" != "${AUTOIMPORT_GROUP}" ]]; then
            issue="wrong group (${group}, expected ${AUTOIMPORT_GROUP})"
        fi

        # Check group rw permissions
        if [[ "${group_perms}" != *r* || "${group_perms}" != *w* ]]; then
            [[ -n "${issue}" ]] && issue+=", "
            issue+="missing group rw perms"
        fi

        # Record issue if found
        if [[ -n "${issue}" ]]; then
            local entry="${item} :: ${issue}"
            bad_files+=("${entry}")
            report+="${entry}"$'\n'
            log "WARNING :: ${entry}"
        fi
    done < <(find "${path}" -mindepth 1 2>/dev/null)

    local returnCode=0
    if ((${#bad_files[@]} > 0)); then
        log "WARNING :: Permission/group check failed for ${path}"
        set_state "permissionIssues" "${report}"
        returnCode=1
    else
        log "DEBUG :: All files in ${path} have correct group and group rw permissions"
        set_state "permissionIssues" "" # clear previous issues
    fi

    log "TRACE :: Exiting CheckPermissions..."
    return $returnCode
}

# Processes a specified file for import
ProcessImport() {
    local importDir="${1}"
    local dirName
    dirName="$(basename "$importDir")"
    local targetName="${dirName#${AUTOIMPORT_IMPORT_MARKER}}" # remove import tag prefix
    targetName="${targetName#" "}"                            # trim leading space if any

    log "INFO :: Processing flagged import folder: ${dirName}"
    GetMovies
    local moviePaths="$(get_state "moviePaths")"

    # Try to find exact match
    local matchPath
    matchPath="$(echo "$moviePaths" | grep -F "/$targetName" || true)"

    if [[ -n "$matchPath" ]]; then
        log "DEBUG :: Match found: ${targetName} -> ${matchPath}"
        if ! CheckPermissions "${importDir}"; then
            local issues
            issues="$(get_state "permissionIssues")"
            echo -e "Permission or ownership issues detected:\n${issues}" >"${importDir}/IMPORT_STATUS.txt"
        else
            local destDir="${AUTOIMPORT_SHARED_PATH}/${targetName}"
            mv "${importDir}" "${destDir}" 2>/dev/null
            log "DEBUG :: Moved '${importDir}' to '${destDir}'"
            NotifyArrForImport "${destDir}"
        fi
    else
        log "DEBUG :: No match found for '${targetName}'"
        echo "No matching movie directory found in ${ARR_NAME} for '$targetName'." >"${importDir}/IMPORT_STATUS.txt"

        # rename to remove import tag so it's not retried
        local newDir="${AUTOIMPORT_DROP_DIR}/${targetName}"
        mv "${importDir}" "${newDir}"
        log "DEBUG :: Removed import tag from '${importDir}'"
    fi
}

# Loops over all directories in the drop directory to process for import
ScanDropDirectory() {
    # Find directories starting with import marker
    log "INFO :: Scanning ${AUTOIMPORT_DROP_DIR} for directories marked with '${AUTOIMPORT_IMPORT_MARKER}'"
    while IFS= read -r dir; do
        ProcessImport "$dir"
    done < <(find "${AUTOIMPORT_DROP_DIR}" -mindepth 1 -maxdepth 1 -type d -name "${AUTOIMPORT_IMPORT_MARKER}*")
    log "INFO :: Scan complete"
}

###### Script Execution #####

### Preamble ###

log "INFO :: Starting ${scriptName}"

log "DEBUG :: AUTOIMPORT_CACHE_HOURS=${AUTOIMPORT_CACHE_HOURS}"
log "DEBUG :: AUTOIMPORT_DROP_DIR=${AUTOIMPORT_DROP_DIR}"
log "DEBUG :: AUTOIMPORT_DOWNLOADCLIENT_NAME=${AUTOIMPORT_DOWNLOADCLIENT_NAME}"
log "DEBUG :: AUTOIMPORT_GROUP=${AUTOIMPORT_GROUP:-}"
log "DEBUG :: AUTOIMPORT_IMPORT_MARKER=${AUTOIMPORT_IMPORT_MARKER}"
log "DEBUG :: AUTOIMPORT_INTERVAL=${AUTOIMPORT_INTERVAL}"
log "DEBUG :: AUTOIMPORT_SHARED_PATH=${AUTOIMPORT_SHARED_PATH}"
log "DEBUG :: AUTOIMPORT_WORK_DIR=${AUTOIMPORT_WORK_DIR}"

### Validation ###

if [[ -z "${AUTOIMPORT_GROUP:-}" ]]; then
    log "ERROR :: AUTOIMPORT_GROUP environment variable is not set. This variable is required for permission checks."
    setUnhealthy
    exit 1
fi

if [[ ! -d "${AUTOIMPORT_DROP_DIR}" ]]; then
    log "ERROR :: AUTOIMPORT_DROP_DIR '${AUTOIMPORT_DROP_DIR}' does not exist"
    exit 1
fi
if [[ ! -d "${AUTOIMPORT_SHARED_PATH}" ]]; then
    log "ERROR :: AUTOIMPORT_SHARED_PATH '${AUTOIMPORT_SHARED_PATH}' does not exist"
    exit 1
fi
if [[ ! -d "${AUTOIMPORT_WORK_DIR}" ]]; then
    log "ERROR :: AUTOIMPORT_WORK_DIR '${AUTOIMPORT_WORK_DIR}' does not exist"
    exit 1
fi

### Main ###

# Initalize state object
init_state

# Verify API access
verifyArrApiAccess

# Create *arr entities
AddDownloadClient

while true; do
    ScanDropDirectory

    log "DEBUG :: Script sleeping for ${AUTOIMPORT_INTERVAL}..."
    sleep ${AUTOIMPORT_INTERVAL}
done

exit 0
