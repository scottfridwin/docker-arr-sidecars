#!/bin/bash
set -euo pipefail

### Script values
scriptName="AutoImport"

#### Import shared utilities
source /app/utilities.sh

#### Constants

# Add custom tags if they don't already exist
AddTags() {
    log "TRACE :: Entering AddTags..."
    local response tagCheck httpCode

    # Fetch existing tags once
    ArrApiRequest "GET" "tag"
    response="$(get_state "arrApiResponse")"

    # Split comma-separated AUTOIMPORT_TAGS into array
    IFS=',' read -ra tags <<<"${AUTOIMPORT_TAGS}"

    for tag in "${tags[@]}"; do
        tag=$(echo "${tag}" | xargs) # Trim whitespace
        log "INFO :: Processing tag: ${tag}"

        # Check if tag already exists
        tagCheck=$(echo "${response}" | jq -r --arg TAG "${tag}" '.[] | select(.label==$TAG) | .label')

        if [ -z "${tagCheck}" ]; then
            log "INFO :: Tag not found, creating tag: ${tag}"
            ArrApiRequest "POST" "tag" "{\"label\":\"${tag}\"}"
            response="$(get_state "arrApiResponse")"
        else
            log "INFO :: Tag already exists: ${tag}"
        fi
    done
    log "TRACE :: Exiting AddTags..."
}

# Add custom download client if it doesn't already exist
AddDownloadClient() {
    log "TRACE :: Entering AddDownloadClient..."
    local downloadClientsData downloadClientCheck httpCode

    # Get list of existing download clients
    ArrApiRequest "GET" "downloadclient"
    downloadClientsData="$(get_state "arrApiResponse")"

    # Check if our custom client already exists
    downloadClientCheck=$(echo "${downloadClientsData}" | jq -r '.[]?.name' | grep -Fx "${AUTOIMPORT_DOWNLOADCLIENT_NAME}" || true)

    if [ -z "${downloadClientCheck}" ]; then
        log "INFO :: ${AUTOIMPORT_DOWNLOADCLIENT_NAME} client not found, creating it..."

        # Get existing tags
        ArrApiRequest "GET" "tag"
        local tagsJson
        tagsJson="$(get_state "arrApiResponse")"

        # Map desired tags to ids
        IFS=',' read -ra tagNames <<<"${AUTOIMPORT_TAGS}"
        tagIds=()
        for t in "${tagNames[@]}"; do
            t=$(echo "$t" | xargs)
            id=$(jq -r --arg label "$t" '.[] | select(.label==$label) | .id' <<<"$tagsJson")
            if [[ -n "$id" && "$id" != "null" ]]; then
                tagIds+=("$id")
            fi
        done
        tagsArray=$(
            IFS=,
            echo "${tagIds[*]}"
        )

        # Build JSON payload
        payload=$(
            cat <<EOF
{
  "enable": true,
  "protocol": "usenet",
  "priority": 10,
  "removeCompletedDownloads": true,
  "removeFailedDownloads": true,
  "name": "${AUTOIMPORT_DOWNLOADCLIENT_NAME}",
  "fields": [
    {"name": "nzbFolder", "value": "${AUTOIMPORT_SHARED_PATH}"},
    {"name": "watchFolder", "value": "${AUTOIMPORT_SHARED_PATH}"}
  ],
  "implementationName": "Usenet Blackhole",
  "implementation": "UsenetBlackhole",
  "configContract": "UsenetBlackholeSettings",
  "infoLink": "https://wiki.servarr.com/lidarr/supported#usenetblackhole",
  "tags": [ ${tagsArray} ]
}
EOF
        )

        # Submit to API
        ArrApiRequest "POST" "downloadclient" "${payload}"

        log "INFO :: Successfully added ${AUTOIMPORT_DOWNLOADCLIENT_NAME} download client."
    else
        log "INFO :: ${AUTOIMPORT_DOWNLOADCLIENT_NAME} download client already exists, skipping creation."
    fi
    log "TRACE :: Exiting AddDownloadClient..."
}

#
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
        # Calculate file age
        local currentTime fileModTime
        currentTime=$(date +%s)
        fileModTime=$(stat -c %Y "${moviesPathsCacheFile}" 2>/dev/null || echo 0)
        local age=$((currentTime - fileModTime))

        if ((age > cacheAgeSeconds)); then
            log "DEBUG :: Movie cache older than ${AUTOIMPORT_CACHE_HOURS}h, refreshing..."
            refreshNeeded=true
        fi
    fi

    if [[ "${refreshNeeded}" == true ]]; then
        # Make API request using your helper (populates arrApiResponse)
        ArrApiRequest "GET" "/api/v3/movie"

        local response
        response="$(get_state "arrApiResponse")"

        if [[ -z "${response}" || "${response}" == "null" ]]; then
            log "ERROR :: Failed to fetch movie list from Radarr API"
            setUnhealthy
            exit 1
        fi

        # Extract movie paths and update cache
        jq -r '.[].path' <<<"${response}" >"${moviesPathsCacheFile}"
        log "INFO :: Movie cache refreshed with $(wc -l <"${moviesPathsCacheFile}") entries"
    fi

    # Load cache contents into memory and store in state
    local moviePaths
    moviePaths="$(<"${moviesPathsCacheFile}")"
    set_state "moviePaths" "${moviePaths}"

    log "TRACE :: Exiting GetMovies..."
}

# Notify *arr to import the specified path
NotifyArrForImport() {
    log "TRACE :: Entering NotifyArrForImport..."
    # $1 -> folder path containing audio files for *arr to import
    local importPath="${1}"

    ArrApiRequest "POST" "command" "{\"name\":\"DownloadedMoviesScan\", \"path\":\"${importPath}\"}"

    log "INFO :: Sent notification to ${ARR_NAME} to import from path: ${importPath}"
    log "TRACE :: Exiting NotifyArrForImport..."
}

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
        group=$(stat -c "%G" "${item}" 2>/dev/null || echo "unknown")

        local group_perms="${perms:4:3}" # characters 5-7 (group perms)
        local issue=""

        # Check correct group if defined
        if [[ "${group}" != "${AUTOIMPORT_GROUP}" ]]; then
            issue="wrong group (${group}, expected ${AUTOIMPORT_GROUP})"
        fi

        # Check group rw permissions
        if [[ "${group_perms}" != *"r"* || "${group_perms}" != *"w"* ]]; then
            [[ -n "${issue}" ]] && issue+=", "
            issue+="missing group rw perms"
        fi

        # Record issue if found
        if [[ -n "${issue}" ]]; then
            local entry="${item} :: ${issue}"
            bad_files+=("${entry}")
            report+="${entry}\n"
            log "WARNING :: ${entry}"
        fi
    done < <(find "${path}" -mindepth 1)

    local returnCode=0
    if ((${#bad_files[@]} > 0)); then
        log "WARNING :: Permission/group check failed for ${path}"
        set_state "permissionIssues" "${report}"
        returnCode=1
    else
        log "DEBUG :: All files in ${path} have correct group and group rw permissions"
        set_state "permissionIssues" "" # clear previous issues
    fi

    log "TRACE :: Exiting CheckPermissions (pass)..."
    return returnCode
}

#
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
            local destDir="${AUTOIMPORT_STAGING_DIR}/${targetName}"
            mv "${importDir}" "${destDir}"
            log "DEBUG :: Moved '${importDir}' to '${destDir}'"
            NotifyArrForImport "${destDir}"
        fi
    else
        log "DEBUG :: No match found for '${targetName}'"
        echo "No matching movie directory found in Radarr for '$targetName'." >"${importDir}/IMPORT_STATUS.txt"

        # rename to remove import tag so it's not retried
        local newDir="${AUTOIMPORT_DROP_DIR}/${targetName}"
        mv "${importDir}" "${newDir}"
        log "DEBUG :: Removed import tag from '${importDir}'"
    fi
}

#
ScanDropDirectory() {
    # Find directories starting with import marker
    log "INFO :: Scanning ${AUTOIMPORT_DROP_DIR} for directories marked with ${AUTOIMPORT_IMPORT_MARKER}"
    while IFS= read -r dir; do
        ProcessImport "$dir"
    done < <(find "${AUTOIMPORT_DROP_DIR}" -mindepth 1 -maxdepth 1 -type d -name "${AUTOIMPORT_IMPORT_MARKER}*")
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
log "DEBUG :: AUTOIMPORT_STAGING_DIR=${AUTOIMPORT_STAGING_DIR}"
log "DEBUG :: AUTOIMPORT_TAGS=${AUTOIMPORT_TAGS}"
log "DEBUG :: AUTOIMPORT_WORK_DIR=${AUTOIMPORT_WORK_DIR}"

### Validation ###

if [[ -z "${AUTOIMPORT_GROUP:-}" ]]; then
    log "ERROR :: AUTOIMPORT_GROUP environment variable is not set. This variable is required for permission checks."
    setUnhealthy
    exit 1
fi

### Main ###

# Initalize state object
init_state

# Verify API access
verifyArrApiAccess

# Create *arr entities
AddTags
AddDownloadClient

while true; do
    ScanDropDirectory

    log "DEBUG :: Script sleeping for ${AUTOIMPORT_INTERVAL}..."
    sleep ${AUTOIMPORT_INTERVAL}
done

exit 0
