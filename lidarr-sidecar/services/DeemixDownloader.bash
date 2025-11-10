#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail

### Script values
scriptName="DeemixDownloader"

#### Import shared utilities
source /app/utilities.sh

#### Constants
readonly VARIOUS_ARTIST_ID="89ad4ac3-39f7-470e-963a-56509c546377"
readonly DEEMIX_DIR="/tmp/deemix"
readonly DEEMIX_CONFIG_PATH="${DEEMIX_DIR}/config.json"
readonly BEETS_DIR="/tmp/beets"
readonly BEETS_CONFIG_PATH="${BEETS_DIR}/beets.yaml"

# Levenshtein Distance calculation
LevenshteinDistance() {
    log "TRACE :: Entering LevenshteinDistance..."
    # $1 -> string 1
    # $2 -> string 2
    local s1="${1}"
    local s2="${2}"
    log "TRACE :: Calculating Levenshtein distance between '${s1}' and '${s2}'"
    local len_s1=${#s1}
    local len_s2=${#s2}

    # If either string is empty, distance is the other's length
    if ((len_s1 == 0)); then
        echo "${len_s2}"
    elif ((len_s2 == 0)); then
        echo "${len_s1}"
    else
        # Initialize 2 arrays for the current and previous row
        local -a prev curr
        for ((j = 0; j <= len_s2; j++)); do
            prev[j]=${j}
        done

        for ((i = 1; i <= len_s1; i++)); do
            curr[0]=${i}
            local s1_char="${s1:i-1:1}"
            for ((j = 1; j <= len_s2; j++)); do
                local s2_char="${s2:j-1:1}"
                local cost=1
                [[ "$s1_char" == "$s2_char" ]] && cost=0

                local del=$((prev[j] + 1))
                local ins=$((curr[j - 1] + 1))
                local sub=$((prev[j - 1] + cost))

                local min=${del}
                ((ins < min)) && min=${ins}
                ((sub < min)) && min=${sub}

                curr[j]=${min}
            done
            prev=("${curr[@]}")
        done

        echo "${curr[len_s2]}"
    fi
    log "TRACE :: Exiting LevenshteinDistance..."
}

# Generic Deezer API call with retries and error handling
CallDeezerAPI() {
    log "TRACE :: Entering CallDeezerAPI..."
    local url="${1}"
    local maxRetries="${AUDIO_DEEZER_API_RETRIES:-3}"
    local retries=0
    local httpCode=0
    local body=""
    local response=""
    local curlExit=0
    local returnCode=1

    while ((retries < maxRetries)); do
        log "DEBUG :: url: ${url}"

        # Run curl safely
        response="$({ curl -sS -w '\n%{http_code}' \
            --connect-timeout 5 \
            --max-time "${AUDIO_DEEZER_API_TIMEOUT:-10}" \
            "${url}" 2>/dev/null || true; })"
        curlExit=$?

        if [[ $curlExit -ne 0 || -z "$response" ]]; then
            log "WARNING :: curl failed (exit $curlExit) for URL ${url}, retrying ($((retries + 1))/${maxRetries})..."
            ((retries++))
            sleep 1
            continue
        fi

        # Extract HTTP code safely
        httpCode="$({ tail -n1 <<<"$response" 2>/dev/null; } || echo 0)"
        body="$({ sed '$d' <<<"$response" 2>/dev/null; } || echo "")"

        # Treat HTTP 000 as failure
        if [[ "$httpCode" == "000" || "$httpCode" == "0" || -z "$httpCode" ]]; then
            log "WARNING :: No HTTP response (000) from Deezer API for URL ${url}, retrying ($((retries + 1))/${maxRetries})..."
            ((retries++))
            sleep 1
            continue
        fi

        # Check for success
        if [[ "$httpCode" -eq 200 && -n "$body" ]]; then
            # Validate JSON safely
            if jq -e . >/dev/null 2>&1 <<<"$body"; then
                set_state "deezerApiResponse" "$body"
                returnCode=0
                break
            else
                log "WARNING :: Invalid JSON body from Deezer API for URL ${url}, retrying ($((retries + 1))/${maxRetries})..."
            fi
        else
            log "WARNING :: Deezer API returned HTTP ${httpCode:-<empty>} for URL ${url}, retrying ($((retries + 1))/${maxRetries})..."
        fi

        ((retries++))
        sleep 1
    done

    if ((returnCode != 0)); then
        log "WARNING :: Failed to get a valid response from Deezer API after ${maxRetries} attempts for URL ${url}"
    fi

    log "TRACE :: Exiting CallDeezerAPI..."
    return "$returnCode"
}

# Fetch Deezer album info with caching (uses CallDeezerAPI)
GetDeezerAlbumInfo() {
    log "TRACE :: Entering GetDeezerAlbumInfo..."
    local albumId="$1"
    local albumCacheFile="${AUDIO_WORK_PATH}/cache/album-${albumId}.json"
    local albumJson=""
    local returnCode=1

    mkdir -p "${AUDIO_WORK_PATH}/cache"

    # Use cache if exists and valid
    if [[ -f "${albumCacheFile}" ]] && jq -e . <"${albumCacheFile}" >/dev/null 2>&1; then
        log "DEBUG :: Using cached Deezer album data for ${albumId}"
        albumJson="$(<"${albumCacheFile}")"
        set_state "deezerAlbumInfo" "${albumJson}"
        return 0
    fi

    # Fetch new data using generic API helper
    local apiUrl="https://api.deezer.com/album/${albumId}"
    if CallDeezerAPI "${apiUrl}"; then
        albumJson="$(get_state "deezerApiResponse")"
        if [[ -n "${albumJson}" ]]; then
            echo "${albumJson}" >"${albumCacheFile}"
            set_state "deezerAlbumInfo" "${albumJson}"
            returnCode=0
        fi
    fi

    if ((returnCode != 0)); then
        log "WARNING :: Failed to get album info for ${albumId}"
    fi

    log "TRACE :: Exiting GetDeezerAlbumInfo..."
    return "${returnCode}"
}

# Fetch Deezer artist albums with caching (uses CallDeezerAPI)
GetDeezerArtistAlbums() {
    log "TRACE :: Entering GetDeezerArtistAlbums..."
    local artistId="$1"
    local artistCacheFile="${AUDIO_WORK_PATH}/cache/artist-${artistId}-albums.json"
    local artistJson=""
    local returnCode=1

    mkdir -p "${AUDIO_WORK_PATH}/cache"

    # Use cache if exists and valid
    if [[ -f "${artistCacheFile}" ]] && jq -e . <"${artistCacheFile}" >/dev/null 2>&1; then
        log "DEBUG :: Using cached Deezer artist album list for ${artistId}"
        artistJson="$(<"${artistCacheFile}")"
        set_state "deezerArtistInfo" "${artistJson}"
        return 0
    fi

    # Fetch new data using generic API helper
    local apiUrl="https://api.deezer.com/artist/${artistId}/albums?limit=1000"
    if CallDeezerAPI "${apiUrl}"; then
        artistJson="$(get_state "deezerApiResponse")"
        if [[ -n "${artistJson}" ]]; then
            echo "${artistJson}" >"${artistCacheFile}"
            set_state "deezerArtistInfo" "${artistJson}"
            returnCode=0
        fi
    fi

    if ((returnCode != 0)); then
        log "WARNING :: Failed to get artist albums for ${artistId}"
    fi

    log "TRACE :: Exiting GetDeezerArtistAlbums..."
    return "${returnCode}"
}

# Add custom download client if it doesn't already exist
AddLidarrDownloadClient() {
    log "TRACE :: Entering AddLidarrDownloadClient..."
    local downloadClientsData downloadClientCheck httpCode

    # Get list of existing download clients
    ArrApiRequest "GET" "downloadclient"
    downloadClientsData="$(get_state "arrApiResponse")"

    # Check if our custom client already exists
    downloadClientCheck=$(echo "${downloadClientsData}" | jq -r '.[]?.name' | grep -Fx "${AUDIO_DOWNLOADCLIENT_NAME}" || true)

    if [ -z "${downloadClientCheck}" ]; then
        log "INFO :: ${AUDIO_DOWNLOADCLIENT_NAME} client not found, creating it..."

        # Build JSON payload
        payload=$(
            cat <<EOF
{
  "enable": true,
  "protocol": "usenet",
  "priority": 10,
  "removeCompletedDownloads": true,
  "removeFailedDownloads": true,
  "name": "${AUDIO_DOWNLOADCLIENT_NAME}",
  "fields": [
    {"name": "nzbFolder", "value": "${AUDIO_SHARED_LIDARR_PATH}"},
    {"name": "watchFolder", "value": "${AUDIO_SHARED_LIDARR_PATH}"}
  ],
  "implementationName": "Usenet Blackhole",
  "implementation": "UsenetBlackhole",
  "configContract": "UsenetBlackholeSettings",
  "infoLink": "https://wiki.servarr.com/lidarr/supported#usenetblackhole",
  "tags": []
}
EOF
        )

        # Submit to API
        ArrApiRequest "POST" "downloadclient" "${payload}"

        log "INFO :: Successfully added ${AUDIO_DOWNLOADCLIENT_NAME} download client."
    else
        log "INFO :: ${AUDIO_DOWNLOADCLIENT_NAME} download client already exists, skipping creation."
    fi
    log "TRACE :: Exiting AddLidarrDownloadClient..."
}

# Clean up old notfound or downloaded entries to allow retries
FolderCleaner() {
    log "TRACE :: Entering FolderCleaner..."
    if [ -d "${AUDIO_DATA_PATH}/notfound" ]; then
        # check for notfound entries older than AUDIO_RETRY_NOTFOUND_DAYS days
        if find "${AUDIO_DATA_PATH}/notfound" -mindepth 1 -type f -mtime +${AUDIO_RETRY_NOTFOUND_DAYS} | read; then
            log "INFO :: Removing prevously notfound lidarr album ids older than ${AUDIO_RETRY_NOTFOUND_DAYS} days to give them a retry..."
            # delete notfound entries older than AUDIO_RETRY_NOTFOUND_DAYS days
            find "${AUDIO_DATA_PATH}/notfound" -mindepth 1 -type f -mtime +${AUDIO_RETRY_NOTFOUND_DAYS} -delete
        fi
    fi
    if [ -d "${AUDIO_DATA_PATH}/downloaded" ]; then
        # check for downloaded entries older than AUDIO_RETRY_DOWNLOADED_DAYS days
        if find "${AUDIO_DATA_PATH}/downloaded" -mindepth 1 -type f -mtime +${AUDIO_RETRY_DOWNLOADED_DAYS} | read; then
            log "INFO :: Removing previously downloaded lidarr album ids older than ${AUDIO_RETRY_DOWNLOADED_DAYS} days to give them a retry..."
            # delete downloaded entries older than AUDIO_RETRY_DOWNLOADED_DAYS days
            find "${AUDIO_DATA_PATH}/downloaded" -mindepth 1 -type f -mtime +${AUDIO_RETRY_DOWNLOADED_DAYS} -delete
        fi
    fi
    if [ -d "${AUDIO_DATA_PATH}/failed" ]; then
        # check for failed entries older than AUDIO_RETRY_FAILED_DAYS days
        if find "${AUDIO_DATA_PATH}/failed" -mindepth 1 -type f -mtime +${AUDIO_RETRY_FAILED_DAYS} | read; then
            log "INFO :: Removing previously failed lidarr album ids older than ${AUDIO_RETRY_FAILED_DAYS} days to give them a retry..."
            # delete failed entries older than AUDIO_RETRY_FAILED_DAYS days
            find "${AUDIO_DATA_PATH}/failed" -mindepth 1 -type f -mtime +${AUDIO_RETRY_FAILED_DAYS} -delete
        fi
    fi
    log "TRACE :: Exiting FolderCleaner..."
}

# Given a MusicBrainz release JSON object, return the title with disambiguation if present
GetReleaseTitleDisambiguation() {
    log "TRACE :: Entering GetReleaseTitleDisambiguation..."
    # $1 -> JSON object for a MusicBrainz release
    local release_json="$1"
    local releaseTitle releaseDisambiguation
    releaseTitle="$(jq -r ".title" <<<"${release_json}")"
    releaseDisambiguation="$(jq -r ".disambiguation" <<<"${release_json}")"
    albumDisambiguation=$(get_state "lidarrAlbumDisambiguation")
    if [ -z "$releaseDisambiguation" ] || [ "$releaseDisambiguation" == "null" ]; then
        releaseDisambiguation=""
    elif [ -z "$albumDisambiguation" ] || [ "$albumDisambiguation" == "null" ]; then
        # Use album disambiguation from Lidarr if release disambiguation is empty
        releaseDisambiguation=" (${albumDisambiguation})"
    else
        releaseDisambiguation=" ($releaseDisambiguation)"
    fi
    echo "${releaseTitle}${releaseDisambiguation}"
    log "TRACE :: Exiting GetReleaseTitleDisambiguation..."
}

# Remove common edition keywords from the end of an album title
RemoveEditionsFromAlbumTitle() {
    title="$1"

    # Normalize spacing and separators
    title=$(echo "$title" | sed -E '
        s/[[:space:]]+/ /g;             # Collapse multiple spaces
        s/[[:space:]]*-[[:space:]]*/ /g; # Replace " - " with space
        s/[[:space:]]*:[[:space:]]*/ /g; # Replace " : " with space
    ')

    # Build a case-insensitive pattern for edition keywords
    edition_pattern='(deluxe|super|special|expanded|anniversary|collector|bonus|exclusive|remaster(ed)?|edition|version|target|apple|spotify|japanese|international)'

    # Remove parentheses that contain edition keywords
    title=$(echo "$title" | sed -E "s/\s*\([^)]*$edition_pattern[^)]*\)\s*$//I")

    # Remove trailing edition keywords, even without parentheses
    title=$(echo "$title" | sed -E "s/\s*[-:]?\s*$edition_pattern( edition| version)?\s*$//I")

    # Repeat once more to catch chained tags (e.g., "Super Deluxe Edition")
    title=$(echo "$title" | sed -E "s/\s*[-:]?\s*$edition_pattern( edition| version)?\s*$//I")

    # Final whitespace trim
    title=$(echo "$title" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')

    echo "$title"
}

# Notify Lidarr to import the downloaded album
NotifyLidarrForImport() {
    log "TRACE :: Entering NotifyLidarrForImport..."
    # $1 -> folder path containing audio files for Lidarr to import
    local importPath="${1}"

    ArrApiRequest "POST" "command" "{\"name\":\"DownloadedAlbumsScan\", \"path\":\"${importPath}\"}"

    log "INFO :: Sent notification to Lidarr to import downloaded album at path: ${importPath}"
    log "TRACE :: Exiting NotifyLidarrForImport..."
}

# Set up Deemix client configuration
SetupDeemix() {
    log "TRACE :: Entering SetupDeemix..."
    log "INFO :: Setting up Deemix client"

    # Determine ARL token
    if [[ -n "${AUDIO_DEEMIX_ARL_FILE}" && -f "${AUDIO_DEEMIX_ARL_FILE}" ]]; then
        DEEMIX_ARL="$(tr -d '\r\n' <"${AUDIO_DEEMIX_ARL_FILE}")"
    else
        log "ERROR :: No Deemix ARL token provided. Set AUDIO_DEEMIX_ARL_FILE."
        setUnhealthy
        exit 1
    fi

    # Copy default config to /tmp
    local defaultConfigFile="/app/config/deemix_config.json"
    if [[ ! -f "${defaultConfigFile}" ]]; then
        log "ERROR :: Default Deemix config not found at ${defaultConfigFile}"
        setUnhealthy
        exit 1
    fi

    mkdir -p "${DEEMIX_DIR}"
    cp -f "${defaultConfigFile}" "${DEEMIX_CONFIG_PATH}"

    # Merge custom config if provided
    if [[ -n "${AUDIO_DEEMIX_CUSTOM_CONFIG}" ]]; then
        local customConfigContent configContent
        # AUDIO_DEEMIX_CUSTOM_CONFIG can be a path to JSON or raw JSON string
        if [[ -f "${AUDIO_DEEMIX_CUSTOM_CONFIG}" ]]; then
            customConfigContent="$(<"${AUDIO_DEEMIX_CUSTOM_CONFIG}")"
        else
            customConfigContent="${AUDIO_DEEMIX_CUSTOM_CONFIG}"
        fi

        # Merge default and custom config; custom overrides defaults
        configContent=$(jq -s '.[0] * .[1]' \
            <(cat "${DEEMIX_CONFIG_PATH}") \
            <(echo "${customConfigContent}"))

        echo "${configContent}" >"${DEEMIX_CONFIG_PATH}"
        log "INFO :: Custom Deemix config merged into ${DEEMIX_CONFIG_PATH}"
    fi

    log "INFO :: Deemix client setup complete. ARL token stored in global DEEMIX_ARL variable."
    log "TRACE :: Exiting SetupDeemix..."
}

# Set up Deemix client configuration
SetupBeets() {
    log "TRACE :: Entering SetupBeets..."
    log "INFO :: Setting up Beets configuration"

    # Copy default config to /tmp
    local defaultConfigFile="/app/config/beets_config.yaml"
    if [[ ! -f "${defaultConfigFile}" ]]; then
        log "ERROR :: Default Beets config not found at ${defaultConfigFile}"
        setUnhealthy
        exit 1
    fi

    mkdir -p "${BEETS_DIR}"
    cp -f "${defaultConfigFile}" "${BEETS_CONFIG_PATH}"

    # Merge custom YAML config if provided
    if [[ -n "${AUDIO_BEETS_CUSTOM_CONFIG}" ]]; then
        local customConfigContent configContent
        # AUDIO_BEETS_CUSTOM_CONFIG can be a path to YAML or raw YAML string
        if [[ -f "${AUDIO_BEETS_CUSTOM_CONFIG}" ]]; then
            customConfigContent="$(<"${AUDIO_BEETS_CUSTOM_CONFIG}")"
        else
            customConfigContent="${AUDIO_BEETS_CUSTOM_CONFIG}"
        fi

        # Merge default and custom config; custom overrides defaults
        configContent=$(yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' \
            "${BEETS_CONFIG_PATH}" \
            <(echo "${customConfigContent}"))

        echo "${configContent}" >"${BEETS_CONFIG_PATH}"
        log "INFO :: Custom Beets config merged into ${BEETS_CONFIG_PATH}"
    fi

    log "INFO :: Beets configuration complete"
    log "TRACE :: Exiting SetupBeets..."
}

# Retrieve and process Lidarr wanted list (missing or cutoff)
ProcessLidarrWantedList() {
    log "TRACE :: Entering ProcessLidarrWantedList..."
    # $1 -> Type of list to process ("missing" or "cutoff")
    local listType=$1
    local searchOrder="releaseDate"
    local searchDirection="descending"
    local pageSize=1000

    log "INFO :: Retrieving ${listType} albums from Lidarr"

    # Get total count of albums
    local response totalRecords
    ArrApiRequest "GET" "wanted/${listType}?page=1&pagesize=1&sortKey=${searchOrder}&sortDirection=${searchDirection}"
    response="$(get_state "arrApiResponse")"
    totalRecords=$(jq -r .totalRecords <<<"$response")
    log "INFO :: Found ${totalRecords} ${listType} albums"

    if ((totalRecords < 1)); then
        log "INFO :: No ${listType} albums to process"
        return
    fi

    # Preload title replacement file
    if [[ -f "${AUDIO_TITLE_REPLACEMENTS_FILE}" ]]; then
        log "DEBUG :: Loading custom title replacements from ${AUDIO_TITLE_REPLACEMENTS_FILE}"
        while IFS="=" read -r key value; do
            key="$(normalize_string "$key")"
            value="$(normalize_string "$value")"
            set_state "titleReplacement_${key}" "$value"
            log "DEBUG :: Loaded title replacement: ${key} -> ${value}"
        done < <(
            jq -r 'to_entries[] | "\(.key)=\(.value)"' "${AUDIO_TITLE_REPLACEMENTS_FILE}" 2>/dev/null
        )
    else
        log "DEBUG :: No custom title replacements file found (${AUDIO_TITLE_REPLACEMENTS_FILE})"
    fi

    # Preload all notfound/downloaded IDs into memory (only once)
    mapfile -t notfound < <(
        find "${AUDIO_DATA_PATH}/notfound/" -type f 2>/dev/null | while read -r f; do
            basename "$f"
        done | sed 's/--.*//' | sort
    ) 2>/dev/null
    mapfile -t downloaded < <(
        find "${AUDIO_DATA_PATH}/downloaded/" -type f 2>/dev/null | while read -r f; do
            basename "$f"
        done | sed 's/--.*//' | sort
    ) 2>/dev/null

    local totalPages=$(((totalRecords + pageSize - 1) / pageSize))

    for ((page = 1; page <= totalPages; page++)); do
        log "INFO :: Downloading page ${page} of ${totalPages} for ${listType} albums"

        # Fetch page of album IDs
        ArrApiRequest "GET" "wanted/${listType}?page=${page}&pagesize=${pageSize}&sortKey=${searchOrder}&sortDirection=${searchDirection}"
        local lidarrPage="$(get_state "arrApiResponse")"
        mapfile -t tocheck < <(
            jq -r '.records[].id // empty' <<<"$lidarrPage" | sort -u
        )

        # Filter out already notfound/downloaded IDs
        mapfile -t tmpList < <(comm -13 <(printf "%s\n" "${notfound[@]}") <(printf "%s\n" "${tocheck[@]}"))
        mapfile -t toProcess < <(comm -13 <(printf "%s\n" "${downloaded[@]}") <(printf "%s\n" "${tmpList[@]}"))

        local recordCount=${#toProcess[@]}
        log "INFO :: ${recordCount} ${listType} albums to process"

        if ((recordCount > 0)); then
            log "INFO :: Starting search for ${recordCount} ${listType} albums"
            for lidarrRecordId in "${toProcess[@]}"; do
                SearchProcess "$lidarrRecordId"
            done
        fi
    done

    log "INFO :: Completed processing ${listType} albums"
    log "TRACE :: Exiting ProcessLidarrWantedList..."
}

# Given a Lidarr album ID, search for and attempt to download the album
SearchProcess() {
    log "TRACE :: Entering SearchProcess..."
    # $1 -> Deezer album ID
    local lidarrAlbumId="$1"
    if [ -z "$lidarrAlbumId" ]; then
        log "WARNING :: No album ID provided to SearchProcess"
        return
    fi
    set_state "lidarrAlbumId" "${lidarrAlbumId}"

    if [ ! -d "${AUDIO_DATA_PATH}/notfound" ]; then
        mkdir -p "${AUDIO_DATA_PATH}"/notfound
    fi

    # Fetch album data from Lidarr
    local lidarrAlbumData
    ArrApiRequest "GET" "album/${lidarrAlbumId}"
    lidarrAlbumData="$(get_state "arrApiResponse")"
    if [ -z "$lidarrAlbumData" ]; then
        log "WARNING :: Lidarr returned no data for album ID ${lidarrAlbumId}"
        return
    fi
    set_state "lidarrAlbumData" "${lidarrAlbumData}" # Cache response in state object

    # Extract artist and album info
    local lidarrArtistData lidarrArtistName lidarrArtistId lidarrArtistForeignArtistId
    lidarrArtistData=$(jq -r ".artist" <<<"$lidarrAlbumData")
    lidarrArtistName=$(jq -r ".artistName" <<<"$lidarrArtistData")
    lidarrArtistId=$(jq -r ".artistMetadataId" <<<"$lidarrArtistData")
    lidarrArtistForeignArtistId=$(jq -r ".foreignArtistId" <<<"$lidarrArtistData")
    set_state "lidarrArtistName" "${lidarrArtistName}"
    set_state "lidarrArtistId" "${lidarrArtistId}"
    set_state "lidarrArtistForeignArtistId" "${lidarrArtistForeignArtistId}"

    local lidarrAlbumTitle lidarrAlbumType lidarrAlbumForeignAlbumId
    lidarrAlbumTitle=$(jq -r ".title" <<<"$lidarrAlbumData")
    lidarrAlbumType=$(jq -r ".albumType" <<<"$lidarrAlbumData")
    lidarrAlbumForeignAlbumId=$(jq -r ".foreignAlbumId" <<<"$lidarrAlbumData")
    set_state "lidarrAlbumForeignAlbumId" "${lidarrAlbumForeignAlbumId}"

    # Extract disambiguation from album info
    local lidarrAlbumDisambiguation
    lidarrAlbumDisambiguation=$(jq -r ".disambiguation" <<<"$lidarrAlbumData")
    set_state "lidarrAlbumDisambiguation" "${lidarrAlbumDisambiguation}"
    if [ -z "$lidarrAlbumDisambiguation" ] || [ "$lidarrAlbumDisambiguation" == "null" ]; then
        lidarrAlbumDisambiguation=""
    else
        lidarrAlbumDisambiguation=" ($lidarrAlbumDisambiguation)"
    fi
    lidarrAlbumTitleWithDisambiguation="${lidarrAlbumTitle}${lidarrAlbumDisambiguation}"
    set_state "lidarrAlbumTitleWithDisambiguation" "${lidarrAlbumTitleWithDisambiguation}"

    # Check if album was previously marked "not found"
    if [ -f "${AUDIO_DATA_PATH}/notfound/${lidarrAlbumId}--${lidarrArtistForeignArtistId}--${lidarrAlbumForeignAlbumId}" ]; then
        log "INFO :: Album \"${lidarrAlbumTitleWithDisambiguation}\" by artist \"${lidarrArtistName}\" was previously marked as not found, skipping..."
        return
    fi

    # Check if album was previously marked "downloaded"
    if [ -f "${AUDIO_DATA_PATH}/downloaded/${lidarrAlbumId}--${lidarrArtistForeignArtistId}--${lidarrAlbumForeignAlbumId}" ]; then
        log "INFO :: Album \"${lidarrAlbumTitleWithDisambiguation}\" by artist \"${lidarrArtistName}\" was previously marked as downloaded, skipping..."
        return
    fi

    # Release date check
    local releaseDate releaseDateClean currentDateClean albumIsNewRelease albumReleaseYear
    releaseDate=$(jq -r ".releaseDate" <<<"$lidarrAlbumData")
    releaseDate=${releaseDate:0:10}                                  # YYYY-MM-DD
    releaseDateClean=$(echo "${releaseDate}" | sed -e 's/[^0-9]//g') # YYYYMMDD
    albumReleaseYear="${releaseDate:0:4}"

    currentDateClean=$(date "+%Y%m%d")
    albumIsNewRelease="false"
    if [[ "${currentDateClean}" -lt "${releaseDateClean}" ]]; then
        log "INFO :: Album \"${lidarrAlbumTitleWithDisambiguation}\" by artist \"${lidarrArtistName}\" has not been released yet (${releaseDate}), skipping..."
        return
    elif ((currentDateClean - releaseDateClean < 8)); then
        albumIsNewRelease="true"
    fi

    log "INFO :: Starting search for album \"${lidarrAlbumTitleWithDisambiguation}\" by artist \"${lidarrArtistName}\""

    # Extract artist links
    local deezerArtistUrl=$(jq -r '.links[]? | select(.name=="deezer") | .url' <<<"${lidarrArtistData}")
    if [ -z "${deezerArtistUrl}" ]; then
        log "WARNING :: Missing Deezer link for artist ${lidarrArtistName}, skipping..."
        return
    fi
    local deezerArtistIds=($(echo "${deezerArtistUrl}" | grep -Eo '[[:digit:]]+' | sort -u))

    # Sort parameter explanations:
    #  - Track count (descending)
    #  - Title length (ascending, as a consistent tiebreaker)

    jq_filter="[.releases[]
    | .normalized_title = (.title | ascii_downcase)
    | .title_length = (.title | length)
] | sort_by(-.trackCount, .title_length)"
    sorted_releases=$(jq -c "${jq_filter}" <<<"${lidarrAlbumData}")

    # Reset search variables
    set_state "bestMatchID" ""
    set_state "bestMatchTitle" ""
    set_state "bestMatchYear" ""
    set_state "bestMatchDistance" 9999
    set_state "bestMatchTrackDiff" 9999
    set_state "bestMatchNumTracks" 0
    set_state "bestMatchContainsCommentary" "false"
    set_state "bestMatchLidarrReleaseInfo" ""
    set_state "bestMatchFormatPriority" ""
    set_state "bestMatchCountryPriority" ""
    set_state "bestMatchLyricTypePreferred" ""
    set_state "bestMatchYearDiff" -1
    set_state "exactMatchFound" "false"

    # Start search loop
    local exactMatchFound="false"
    # Process each release from Lidarr in sorted order
    local releases
    mapfile -t releasesArray < <(jq -c '.[]' <<<"$sorted_releases")
    for release_json in "${releasesArray[@]}"; do
        local lidarrReleaseTitle="$(jq -r ".title" <<<"${release_json}")"
        local lidarrReleaseTitleWithDisambiguation="$(GetReleaseTitleDisambiguation "${release_json}")"
        local lidarrReleaseTrackCount="$(jq -r ".trackCount" <<<"${release_json}")"
        local lidarrReleaseForeignId="$(jq -r ".foreignReleaseId" <<<"${release_json}")"
        local lidarrReleaseFormat="$(jq -r ".format" <<<"${release_json}")"
        local lidarrReleaseCountries="$(jq -r '.country // [] | join(",")' <<<"${release_json}")"
        local lidarrReleaseFormatPriority="$(FormatPriority "${lidarrReleaseFormat}")"
        local lidarrReleaseCountryPriority="$(CountriesPriority "${lidarrReleaseCountries}")"
        local lidarrReleaseDate=$(jq -r '.releaseDate' <<<"${release_json}")
        if [ -n "${lidarrReleaseDate}" ] && [ "${lidarrReleaseDate}" != "null" ]; then
            lidarrReleaseYear="${lidarrReleaseDate:0:4}"
        elif [ -n "${albumReleaseYear}" ] && [ "${albumReleaseYear}" != "null" ]; then
            lidarrReleaseYear="${albumReleaseYear}"
        else
            lidarrReleaseYear=""
        fi
        set_state "lidarrReleaseInfo" "${release_json}"
        set_state "lidarrReleaseTitle" "${lidarrReleaseTitle}"
        set_state "lidarrReleaseTitleWithDisambiguation" "${lidarrReleaseTitleWithDisambiguation}"
        set_state "lidarrReleaseTrackCount" "${lidarrReleaseTrackCount}"
        set_state "lidarrReleaseForeignId" "${lidarrReleaseForeignId}"
        set_state "lidarrReleaseFormatPriority" "${lidarrReleaseFormatPriority}"
        set_state "lidarrReleaseCountryPriority" "${lidarrReleaseCountryPriority}"
        set_state "lidarrReleaseYear" "${lidarrReleaseYear}"
        log "DEBUG :: Processing Lidarr release \"${lidarrReleaseTitleWithDisambiguation}\" with ${lidarrReleaseTrackCount} tracks, format: ${lidarrReleaseFormat} (priority ${lidarrReleaseFormatPriority}), countries: ${lidarrReleaseCountries} (priority ${lidarrReleaseCountryPriority}), year: ${lidarrReleaseYear}"

        # If a exact match was already found, only process releases with more tracks
        exactMatchFound="$(get_state "exactMatchFound")"
        if [ "${exactMatchFound}" == "true" ]; then
            # If current release has fewer tracks than best match, skip it
            local bestMatchNumTracks
            bestMatchNumTracks="$(get_state "bestMatchNumTracks")"
            if ((lidarrReleaseTrackCount < bestMatchNumTracks)); then
                log "DEBUG :: Already found an exact match with ${bestMatchNumTracks} tracks, skipping release \"${lidarrReleaseTitleWithDisambiguation}\" with ${lidarrReleaseTrackCount} tracks"
                continue
            fi
        fi

        # TODO: Enhance this functionality to intelligently handle releases that are expected to have these keywords
        # Ignore instrumental-like releases if configured
        if [[ "${AUDIO_IGNORE_INSTRUMENTAL_RELEASES}" == "true" ]]; then
            # Convert comma-separated list into an alternation pattern for Bash regex
            IFS=',' read -r -a keywordArray <<<"${AUDIO_INSTRUMENTAL_KEYWORDS}"
            keywordPattern="($(
                IFS="|"
                echo "${keywordArray[*]}"
            ))" # join array with | for pattern matching

            if [[ "${lidarrAlbumTitleWithDisambiguation}" =~ ${keywordPattern} ]]; then
                log "INFO :: Album \"${lidarrAlbumTitleWithDisambiguation}\" matched instrumental keyword (${AUDIO_INSTRUMENTAL_KEYWORDS}), skipping..."
                continue
            elif [[ "${lidarrReleaseTitleWithDisambiguation,,}" =~ ${keywordPattern,,} ]]; then
                log "INFO :: Release \"${lidarrReleaseTitleWithDisambiguation}\" matched instrumental keyword (${AUDIO_INSTRUMENTAL_KEYWORDS}), skipping..."
                continue
            fi
        fi

        # Check for commentary keywords in the name of the album
        # TODO: Currently just a text match in the name of the album. Could be better
        local lidarrReleaseContainsCommentary="false"
        IFS=',' read -r -a commentaryArray <<<"${AUDIO_COMMENTARY_KEYWORDS}"
        commentaryPattern="($(
            IFS="|"
            echo "${commentaryArray[*]}"
        ))" # join array with | for pattern matching

        if [[ "${lidarrAlbumTitleWithDisambiguation,,}" =~ ${commentaryPattern,,} ]]; then
            log "DEBUG :: Album \"${lidarrAlbumTitleWithDisambiguation}\" matched commentary keyword (${AUDIO_COMMENTARY_KEYWORDS})"
            lidarrReleaseContainsCommentary="true"
        elif [[ "${lidarrReleaseTitleWithDisambiguation,,}" =~ ${commentaryPattern,,} ]]; then
            log "DEBUG :: Release \"${lidarrReleaseTitleWithDisambiguation}\" matched commentary keyword (${AUDIO_COMMENTARY_KEYWORDS})"
            lidarrReleaseContainsCommentary="true"
        fi
        set_state "lidarrReleaseContainsCommentary" "${lidarrReleaseContainsCommentary}"

        # Optionally de-prioritize releases that contain commentary tracks
        bestMatchContainsCommentary=$(get_state "bestMatchContainsCommentary")
        if [[ "${AUDIO_DEPRIORITIZE_COMMENTARY_RELEASES}" == "true" && "${lidarrReleaseContainsCommentary}" == "true" && "${bestMatchContainsCommentary}" == "false" ]]; then
            log "INFO :: Already found a match without commentary. Skipping commentary album ${lidarrReleaseTitleWithDisambiguation}"
            continue
        fi

        # Loop over lidarrReleaseTitle with disambiguation and without
        for searchReleaseTitle in "${lidarrReleaseTitleWithDisambiguation}" "${lidarrReleaseTitle}"; do
            set_state "searchReleaseTitle" "${searchReleaseTitle}"
            # First search through the artist's Deezer albums to find a match on album title and track count
            log "DEBUG :: Starting search with searchReleaseTitle: ${searchReleaseTitle}"
            if [ "${lidarrArtistForeignArtistId}" != "${VARIOUS_ARTIST_ID}" ]; then # Skip various artists
                for dId in "${!deezerArtistIds[@]}"; do
                    local deezerArtistId="${deezerArtistIds[$dId]}"
                    ArtistDeezerSearch "${deezerArtistId}"
                done
            fi

            # Fuzzy search
            exactMatchFound="$(get_state "exactMatchFound")"
            if [ "${exactMatchFound}" == "false" ]; then
                FuzzyDeezerSearch
            fi
        done
    done

    log "INFO :: Search process complete..."

    # Download the best match that was found
    local bestMatchID="$(get_state "bestMatchID")"
    if [[ -n "${bestMatchID}" ]]; then
        DownloadBestMatch
    else
        log "INFO :: Album not found"
        if [ "${albumIsNewRelease}" == "true" ]; then
            log "INFO :: Skip marking album as not found because it's a new release..."
        else
            log "INFO :: Marking album as not found"
            if [ ! -f "${AUDIO_DATA_PATH}/notfound/${lidarrAlbumId}--${lidarrArtistForeignArtistId}--${lidarrAlbumForeignAlbumId}" ]; then
                touch "${AUDIO_DATA_PATH}/notfound/${lidarrAlbumId}--${lidarrArtistForeignArtistId}--${lidarrAlbumForeignAlbumId}"
            fi
        fi
    fi

    log "TRACE :: Exiting SearchProcess..."
}

# Search Deezer artist's albums for matches
ArtistDeezerSearch() {
    log "TRACE :: Entering ArtistDeezerSearch..."
    # $1 -> Deezer Artist ID
    local artistId="${1}"

    # Get Deezer artist album list
    local artistAlbums filteredAlbums resultsCount
    GetDeezerArtistAlbums "${artistId}"
    local returnCode=$?
    if [ "$returnCode" -eq 0 ]; then
        artistAlbums="$(get_state "deezerArtistInfo")"
        resultsCount=$(jq '.total' <<<"${artistAlbums}")
        log "INFO :: Searching albums for Artist ${artistId} (Total Albums: ${resultsCount} found)"

        # Pass filtered albums to the CalculateBestMatch function
        if ((resultsCount > 0)); then
            CalculateBestMatch <<<"${artistAlbums}"
        fi
    else
        log "WARNING :: Failed to fetch album list for Deezer artist ID ${artistId}"
    fi
    log "TRACE :: Exiting ArtistDeezerSearch..."
}

# Fuzzy search Deezer for albums matching title and artist
FuzzyDeezerSearch() {
    log "TRACE :: Entering FuzzyDeezerSearch..."

    local deezerSearch
    local resultsCount
    local url

    local lidarrAlbumData="$(get_state "lidarrAlbumData")"
    local searchReleaseTitle="$(get_state "searchReleaseTitle")"
    local lidarrArtistForeignArtistId="$(get_state "lidarrArtistForeignArtistId")"
    local lidarrArtistName="$(get_state "lidarrArtistName")"

    log "INFO :: Fuzzy searching for '${searchReleaseTitle}' by '${lidarrArtistName}'..."

    # Prepare search terms
    local albumTitleSearch albumArtistNameSearch lidarrAlbumReleaseTitleSearchClean lidarrArtistNameSearchClean
    lidarrAlbumReleaseTitleSearchClean="$(normalize_string "${searchReleaseTitle}")"
    lidarrArtistNameSearchClean="$(normalize_string "${lidarrArtistName}")"
    albumTitleSearch="$(jq -R -r @uri <<<$(remove_quotes "${lidarrAlbumReleaseTitleSearchClean}"))"
    albumArtistNameSearch="$(jq -R -r @uri <<<$(remove_quotes "${lidarrArtistNameSearchClean}"))"

    # Build search URL
    if [[ "${lidarrArtistForeignArtistId}" == "${VARIOUS_ARTIST_ID}" ]]; then
        url="https://api.deezer.com/search?q=album:%22${albumTitleSearch}%22&strict=on&limit=20"
    else
        url="https://api.deezer.com/search?q=artist:%22${albumArtistNameSearch}%22%20album:%22${albumTitleSearch}%22&strict=on&limit=20"
    fi

    # Call Deezer API
    CallDeezerAPI "${url}"
    local returnCode=$?
    if ((returnCode == 0)); then
        deezerSearch="$(get_state "deezerApiResponse")"
        log "TRACE :: deezerSearch: ${deezerSearch}"
        if [[ -n "${deezerSearch}" ]]; then
            resultsCount=$(jq '.total' <<<"${deezerSearch}")
            log "DEBUG :: ${resultsCount} search results found for '${searchReleaseTitle}' by '${lidarrArtistName}'"
            if ((resultsCount > 0)); then
                # Filter to unique albums by ID and wrap in object with "data" and "total"
                local formattedAlbums
                formattedAlbums="$(jq '{
                    data: ([.data[]] | unique_by(.album.id | select(. != null)) | map(.album)),
                    total: ([.data[] | .album.id] | unique | length)
                }' <<<"${deezerSearch}")"

                log "TRACE :: Formatted unique album data: ${formattedAlbums}"
                CalculateBestMatch <<<"${formattedAlbums}"
            else
                log "DEBUG :: No results found via Fuzzy Search for '${searchReleaseTitle}' by '${lidarrArtistName}'"
            fi
        else
            log "WARNING :: Deezer Fuzzy Search API response missing expected fields"
        fi
    else
        log "WARNING :: Deezer Fuzzy Search failed for '${searchReleaseTitle}' by '${lidarrArtistName}'"
    fi
    log "TRACE :: Exiting FuzzyDeezerSearch..."
}

# Given a JSON array of Deezer albums, find the best match based on title similarity and track count
CalculateBestMatch() {
    log "TRACE :: Entering CalculateBestMatch..."
    # stdin -> JSON array containing list of Deezer albums to check

    local albums albumsRaw albumsCount
    albumsRaw=$(cat) # read JSON array from stdin
    albumsCount=$(jq '.total' <<<"${albumsRaw}")
    albums=$(jq '[.data[]]' <<<"${albumsRaw}")

    local lidarrReleaseInfo="$(get_state "lidarrReleaseInfo")"
    local lidarrReleaseTrackCount="$(get_state "lidarrReleaseTrackCount")"
    local searchReleaseTitle="$(get_state "searchReleaseTitle")"
    local lidarrReleaseContainsCommentary="$(get_state "lidarrReleaseContainsCommentary")"
    local lidarrReleaseFormatPriority="$(get_state "lidarrReleaseFormatPriority")"
    local lidarrReleaseCountryPriority="$(get_state "lidarrReleaseCountryPriority")"
    # Normalize Lidarr release title
    local searchReleaseTitleClean
    searchReleaseTitleClean="$(normalize_string "${searchReleaseTitle}")"
    searchReleaseTitleClean="${searchReleaseTitleClean:0:130}"

    log "DEBUG :: Calculating best match for \"${searchReleaseTitleClean}\" with ${albumsCount} Deezer albums to compare"
    for ((i = 0; i < albumsCount; i++)); do
        local deezerAlbumData deezerAlbumID deezerAlbumTitle deezerAlbumTitleClean
        local deezerAlbumTrackCount deezerReleaseYear
        local diff trackDiff

        deezerAlbumData=$(jq -c ".[$i]" <<<"${albums}")
        deezerAlbumID=$(jq -r ".id" <<<"${deezerAlbumData}")
        deezerAlbumTitle=$(jq -r ".title" <<<"${deezerAlbumData}")
        deezerAlbumExplicitLyrics=$(jq -r ".explicit_lyrics" <<<"${deezerAlbumData}")

        # Skip albums that don't match the lyric type filter
        if [[ "${AUDIO_LYRIC_TYPE}" == "require-clean" && "${deezerAlbumExplicitLyrics}" == "true" ]]; then
            log "DEBUG :: Skipping Deezer album ID ${deezerAlbumID} (${deezerAlbumTitle}) due to explicit lyrics filter"
            continue
        elif [[ "${AUDIO_LYRIC_TYPE}" == "require-explicit" && "${deezerAlbumExplicitLyrics}" == "false" ]]; then
            log "DEBUG :: Skipping Deezer album ID ${deezerAlbumID} (${deezerAlbumTitle}) due to clean lyrics filter"
            continue
        fi

        # --- Normalize title ---
        deezerAlbumTitleClean="$(normalize_string "$deezerAlbumTitle")"
        deezerAlbumTitleClean="${deezerAlbumTitleClean:0:130}"
        deezerAlbumTitleEditionless="$(RemoveEditionsFromAlbumTitle "${deezerAlbumTitleClean}")"
        log "DEBUG :: Comparing lidarr release \"${searchReleaseTitleClean}\" to Deezer album ID ${deezerAlbumID} with title \"${deezerAlbumTitleClean}\" (editionless: \"${deezerAlbumTitleEditionless}\" and explicit=${deezerAlbumExplicitLyrics})"

        # Apply custom replacements if defined
        # In some cases, albums have strange translations that need to happen for comparison to work.
        # Example: For Taylor Swift's 1989, Deezer has "1989 (Deluxe Edition)" but musicbrainz has "1989 D.L.X." because that is the title on the album
        replacement="$(get_state "titleReplacement_${deezerAlbumTitleClean}")"
        if [[ -n "$replacement" ]]; then
            log "DEBUG :: Title matched replacement rule: \"${deezerAlbumTitleClean}\" → \"${replacement}\""
            deezerAlbumTitleClean="${replacement}"
        fi
        replacement="$(get_state "titleReplacement_${deezerAlbumTitleEditionless}")"
        if [[ -n "$replacement" ]]; then
            log "DEBUG :: Title matched replacement rule: \"${deezerAlbumTitleEditionless}\" → \"${replacement}\""
            deezerAlbumTitleEditionless="${replacement}"
        fi

        # Get album info from Deezer
        GetDeezerAlbumInfo "${deezerAlbumID}"
        local returnCode=$?
        if [ "$returnCode" -eq 0 ]; then
            deezerAlbumData="$(get_state "deezerAlbumInfo")"
            deezerAlbumTrackCount=$(jq -r .nb_tracks <<<"${deezerAlbumData}")
            deezerReleaseYear=$(jq -r .release_date <<<"${deezerAlbumData}")
            deezerReleaseYear="${deezerReleaseYear:0:4}"
        else
            log "WARNING :: Failed to fetch album info for Deezer album ID ${deezerAlbumID}, skipping..."
            continue
        fi

        # Check both with and without edition info
        local titlesToCheck=()
        titlesToCheck+=("${deezerAlbumTitleClean}")
        if [[ "${deezerAlbumTitleClean}" != "${deezerAlbumTitleEditionless}" ]]; then
            titlesToCheck+=("${deezerAlbumTitleEditionless}")
            log "DEBUG :: Checking both edition and editionless titles: \"${deezerAlbumTitleClean}\", \"${deezerAlbumTitleEditionless}\""
        fi
        for titleVariant in "${titlesToCheck[@]}"; do
            # Compute Levenshtein distance and track count difference
            diff=$(LevenshteinDistance "${searchReleaseTitleClean,,}" "${titleVariant,,}")
            trackDiff=$((lidarrReleaseTrackCount > deezerAlbumTrackCount ? lidarrReleaseTrackCount - deezerAlbumTrackCount : deezerAlbumTrackCount - lidarrReleaseTrackCount))

            if ((diff <= ${AUDIO_MATCH_DISTANCE_THRESHOLD})); then
                log "INFO :: Potential match found :: \"${titleVariant,,}\" :: Distance=${diff} TrackDiff=${trackDiff} LidarrYear=${lidarrReleaseYear}"
            else
                log "DEBUG :: Album \"${titleVariant,,}\" does not meet matching threshold (Distance=${diff}), skipping..."
                continue
            fi

            # Check if lyric type is preferred
            local lyricTypePreferred=true
            case "${AUDIO_LYRIC_TYPE}" in
            prefer-clean)
                if [ "${deezerAlbumExplicitLyrics}" == "true" ]; then
                    lyricTypePreferred=false
                fi
                ;;
            prefer-explicit)
                if [ "${deezerAlbumExplicitLyrics}" == "false" ]; then
                    lyricTypePreferred=false
                fi
                ;;
            esac

            # Keep track of the best match so far, using this criteria:
            # 1. Lowest Levenshtein distance
            # 2. Lowest track count difference
            # 3. Closest release year to Lidarr album
            # 4. Highest number of tracks
            # 5. Preferred lyric type
            # 6. Preferred format priority
            # 7. Preferred country priority
            if isBetterMatch "$diff" "$trackDiff" "$deezerAlbumTrackCount" "$lyricTypePreferred" "$lidarrReleaseFormatPriority" "$lidarrReleaseCountryPriority" "$deezerReleaseYear"; then
                # Check if we tried and failed to download this album before
                if [ -f "${AUDIO_DATA_PATH}/failed/${deezerAlbumID}" ]; then
                    log "WARNING :: Album \"${titleVariant}\" previously failed to download (deezer: ${deezerAlbumID})...Looking for a different match..."
                    continue
                fi

                # Update best match globals
                set_state "bestMatchID" "${deezerAlbumID}"
                set_state "bestMatchTitle" "${titleVariant}"
                set_state "bestMatchYear" "${deezerReleaseYear}"
                set_state "bestMatchDistance" "${diff}"
                set_state "bestMatchTrackDiff" "${trackDiff}"
                set_state "bestMatchNumTracks" "${deezerAlbumTrackCount}"
                set_state "bestMatchFormatPriority" "${lidarrReleaseFormatPriority}"
                set_state "bestMatchCountryPriority" "${lidarrReleaseCountryPriority}"
                set_state "bestMatchLyricTypePreferred" "${lyricTypePreferred}"
                set_state "bestMatchContainsCommentary" "${lidarrReleaseContainsCommentary}"
                set_state "bestMatchLidarrReleaseInfo" "${lidarrReleaseInfo}"
                set_state "bestMatchYearDiff" "$(get_state "currentYearDiff")"
                log "INFO :: New best match :: ${titleVariant} (${deezerReleaseYear}) :: Distance=${diff} TrackDiff=${trackDiff} NumTracks=${deezerAlbumTrackCount} YearDiff=$(get_state "currentYearDiff") LyricPreferred=${lyricTypePreferred} FormatPriority=${lidarrReleaseFormatPriority} CountryPriority=${lidarrReleaseCountryPriority}"
                if ((diff == 0 && trackDiff == 0)); then
                    log "INFO :: Exact match found :: ${titleVariant} (${deezerReleaseYear}) with ${deezerAlbumTrackCount} tracks"
                    set_state "exactMatchFound" "true"
                fi
            fi
        done
    done

    log "TRACE :: Exiting CalculateBestMatch..."
}

# Determine if the current candidate is a better match than the best match so far
isBetterMatch() {
    local diff="$1"
    local trackDiff="$2"
    local deezerAlbumTrackCount="$3"
    local lyricTypePreferred="$4"
    local lidarrReleaseFormatPriority="$5"
    local lidarrReleaseCountryPriority="$6"
    local deezerAlbumYear="$7"

    local bestMatchDistance="$(get_state "bestMatchDistance")"
    local bestMatchTrackDiff="$(get_state "bestMatchTrackDiff")"
    local bestMatchNumTracks="$(get_state "bestMatchNumTracks")"
    local bestMatchLyricTypePreferred="$(get_state "bestMatchLyricTypePreferred")"
    local bestMatchFormatPriority="$(get_state "bestMatchFormatPriority")"
    local bestMatchCountryPriority="$(get_state "bestMatchCountryPriority")"
    local bestMatchYearDiff="$(get_state "bestMatchYearDiff")"

    # Get the expected release year from Lidarr
    local lidarrAlbumData="$(get_state "lidarrAlbumData")"
    local lidarrReleaseYear=$(get_state "lidarrReleaseYear")

    # Calculate year difference
    local yearDiff=-1
    local yearDiffEvaluation="worse"
    if [[ -n "${deezerAlbumYear}" && -n "${lidarrReleaseYear}" && "${deezerAlbumYear}" != "null" && "${lidarrReleaseYear}" != "null" ]]; then
        yearDiff=$((deezerAlbumYear - lidarrReleaseYear))
        yearDiff=${yearDiff#-} # absolute value
    fi
    set_state "currentYearDiff" "${yearDiff}"
    log "DEBUG :: Calculated yearDiff=${yearDiff} between Deezer year ${deezerAlbumYear} and Lidarr year ${lidarrReleaseYear}"

    # Check if the current release year difference is better/worse/same than the best match so far
    # If the best match year diff is not set, any year diff is better
    # If the current year diff is not set, it is worse than any set year diff
    # If both are set, compare numerically
    if [[ "${bestMatchYearDiff}" -eq -1 && "${yearDiff}" -ne -1 ]]; then
        yearDiffEvaluation="better"
    elif [[ "${bestMatchYearDiff}" -ne -1 && "${yearDiff}" -eq -1 ]]; then
        yearDiffEvaluation="worse"
    elif [[ "${bestMatchYearDiff}" -ne -1 && "${yearDiff}" -ne -1 ]]; then
        if ((yearDiff < bestMatchYearDiff)); then
            yearDiffEvaluation="better"
        elif ((yearDiff == bestMatchYearDiff)); then
            yearDiffEvaluation="same"
        else
            yearDiffEvaluation="worse"
        fi
    fi

    log "DEBUG :: Comparing candidate (Diff=${diff}, TrackDiff=${trackDiff}, YearDiff=${yearDiff} (${yearDiffEvaluation}), NumTracks=${deezerAlbumTrackCount}, LyricPreferred=${lyricTypePreferred}, FormatPriority=${lidarrReleaseFormatPriority}, CountryPriority=${lidarrReleaseCountryPriority}) against best match (Diff=${bestMatchDistance}, TrackDiff=${bestMatchTrackDiff}, YearDiff=${bestMatchYearDiff}, NumTracks=${bestMatchNumTracks}, LyricPreferred=${bestMatchLyricTypePreferred}, FormatPriority=${bestMatchFormatPriority}, CountryPriority=${bestMatchCountryPriority})"
    # Compare against current best-match globals
    # Return 0 (true) if current candidate is better, 1 (false) otherwise
    if ((diff < bestMatchDistance)); then
        return 0
    elif ((diff == bestMatchDistance)) && ((trackDiff < bestMatchTrackDiff)); then
        return 0
    elif ((diff == bestMatchDistance)) && ((trackDiff == bestMatchTrackDiff)) && [[ "$yearDiffEvaluation" == "better" ]]; then
        return 0
    elif ((diff == bestMatchDistance)) && ((trackDiff == bestMatchTrackDiff)) && [[ "$yearDiffEvaluation" == "same" ]] && ((deezerAlbumTrackCount > bestMatchNumTracks)); then
        return 0
    elif ((diff == bestMatchDistance)) && ((trackDiff == bestMatchTrackDiff)) && [[ "$yearDiffEvaluation" == "same" ]] && ((deezerAlbumTrackCount == bestMatchNumTracks)) &&
        [[ "$lyricTypePreferred" == "true" && "$bestMatchLyricTypePreferred" == "false" ]]; then
        return 0
    elif ((diff == bestMatchDistance)) && ((trackDiff == bestMatchTrackDiff)) && [[ "$yearDiffEvaluation" == "same" ]] && ((deezerAlbumTrackCount == bestMatchNumTracks)) &&
        [[ "$lyricTypePreferred" == "$bestMatchLyricTypePreferred" ]] &&
        ((lidarrReleaseFormatPriority < bestMatchFormatPriority)); then
        return 0
    elif ((diff == bestMatchDistance)) && ((trackDiff == bestMatchTrackDiff)) && [[ "$yearDiffEvaluation" == "same" ]] && ((deezerAlbumTrackCount == bestMatchNumTracks)) &&
        [[ "$lyricTypePreferred" == "$bestMatchLyricTypePreferred" ]] &&
        ((lidarrReleaseFormatPriority == bestMatchFormatPriority)) &&
        ((lidarrReleaseCountryPriority < bestMatchCountryPriority)); then
        return 0
    fi

    return 1
}

# Given a JSON array of Deezer albums, find the best match based on title similarity and track count
DownloadBestMatch() {
    log "TRACE :: Entering DownloadBestMatch..."

    local bestMatchID="$(get_state "bestMatchID")"
    local bestMatchTitle="$(get_state "bestMatchTitle")"
    local bestMatchYear="$(get_state "bestMatchYear")"
    local bestMatchDistance="$(get_state "bestMatchDistance")"
    local bestMatchTrackDiff="$(get_state "bestMatchTrackDiff")"
    local bestMatchNumTracks="$(get_state "bestMatchNumTracks")"
    local downloadedLidarrReleaseInfo="$(get_state "bestMatchLidarrReleaseInfo")"
    set_state "downloadedLidarrReleaseInfo" "${downloadedLidarrReleaseInfo}"

    # Download the best match that was found
    log "INFO :: Using best match :: ${bestMatchTitle} (${bestMatchYear}) :: Distance=${bestMatchDistance} TrackDiff=${bestMatchTrackDiff} NumTracks=${bestMatchNumTracks}"

    GetDeezerAlbumInfo "${bestMatchID}"
    local returnCode=$?
    if [ "$returnCode" -eq 0 ]; then
        local deezerAlbumData="$(get_state "deezerAlbumInfo")"
        DownloadProcess <<<"${deezerAlbumData}"
    else
        log "WARNING :: Failed to fetch album info for Deezer album ID ${bestMatchID}. Unable to download..."
    fi

    log "TRACE :: Exiting DownloadBestMatch..."
}

# Download album using deemix
DownloadProcess() {
    log "TRACE :: Entering DownloadProcess..."
    # stdin - JSON data from Deezer API for the album

    local deezerAlbumJson
    deezerAlbumJson=$(cat) # read JSON object from stdin

    # Create Required Directories
    if [ ! -d "${AUDIO_WORK_PATH}/staging" ]; then
        mkdir -p "${AUDIO_WORK_PATH}"/staging
    else
        rm -rf "${AUDIO_WORK_PATH}"/staging/*
    fi

    if [ ! -d "${AUDIO_WORK_PATH}/complete" ]; then
        mkdir -p "${AUDIO_WORK_PATH}"/complete
    else
        rm -rf "${AUDIO_WORK_PATH}"/complete/*
    fi

    if [ ! -d "${AUDIO_WORK_PATH}/cache" ]; then
        mkdir -p "${AUDIO_WORK_PATH}"/cache
    else
        # Delete only files (and empty directories) older than $AUDIO_CACHE_MAX_AGE_DAYS
        find "${AUDIO_WORK_PATH}/cache" -mindepth 1 -mtime +"${AUDIO_CACHE_MAX_AGE_DAYS}" -exec rm -rf {} +
    fi

    if [ ! -d "${AUDIO_DATA_PATH}/downloaded" ]; then
        mkdir -p "${AUDIO_DATA_PATH}"/downloaded
    fi

    if [ ! -d "${AUDIO_DATA_PATH}/failed" ]; then
        mkdir -p "${AUDIO_DATA_PATH}"/failed
    fi

    if [ ! -d "${AUDIO_SHARED_LIDARR_PATH}" ]; then
        log "ERROR :: Shared Lidarr Path not found: ${AUDIO_SHARED_LIDARR_PATH}"
        setUnhealthy
        exit 1
    fi

    local deezerAlbumId deezerAlbumTitle deezerAlbumTitleClean deezerAlbumTrackCount deezerArtistName deezerArtistNameClean downloadedReleaseDate downloadedReleaseYear
    deezerAlbumId=$(jq -r ".id" <<<"${deezerAlbumJson}")
    deezerAlbumTitle=$(jq -r ".title" <<<"${deezerAlbumJson}" | head -n1)
    deezerAlbumTitleClean=$(normalize_string "$deezerAlbumTitle")
    deezerAlbumTrackCount="$(jq -r .nb_tracks <<<"${deezerAlbumJson}")"
    deezerArtistName=$(jq -r '.artist.name' <<<"${deezerAlbumJson}")
    deezerArtistNameClean=$(normalize_string "$deezerArtistName")
    downloadedReleaseDate=$(jq -r .release_date <<<"${deezerAlbumJson}")
    downloadedReleaseYear="${downloadedReleaseDate:0:4}"

    # Check if previously downloaded or failed download
    local lidarrArtistForeignArtistId="$(get_state "lidarrArtistForeignArtistId")"
    local lidarrAlbumForeignAlbumId="$(get_state "lidarrAlbumForeignAlbumId")"
    if [ -f "${AUDIO_DATA_PATH}/downloaded/${lidarrAlbumId}--${lidarrArtistForeignArtistId}--${lidarrAlbumForeignAlbumId}" ]; then
        log "WARNING :: Album \"${deezerAlbumTitle}\" previously downloaded (deezer: ${deezerAlbumId}, lidarr:${lidarrAlbumId})...Skipping..."
        return
    fi
    if [ -f "${AUDIO_DATA_PATH}/failed/${deezerAlbumId}" ]; then
        log "WARNING :: Album \"${deezerAlbumTitle}\" previously failed to download (deezer: ${deezerAlbumId}, lidarr:${lidarrAlbumId})...Skipping..."
        return
    fi

    local downloadTry=0
    while true; do
        downloadTry=$(($downloadTry + 1))

        # Stop trying after too many attempts
        if ((downloadTry >= AUDIO_DOWNLOAD_ATTEMPT_THRESHOLD)); then
            log "WARNING :: Album \"${deezerAlbumTitle}\" failed to download after ${downloadTry} attempts...Skipping..."
            touch "${AUDIO_DATA_PATH}/failed/${deezerAlbumId}"
            return
        fi

        log "INFO :: Download attempt #${downloadTry} for album \"${deezerAlbumTitle}\""
        (
            cd ${DEEMIX_DIR}
            echo "${DEEMIX_ARL}" | deemix \
                -p "${AUDIO_WORK_PATH}/staging" \
                "https://www.deezer.com/album/${deezerAlbumId}" 2>&1

            # Clean up any temporary deemix data
            rm -rf /tmp/deemix-imgs 2>/dev/null || true
        )

        # Check if any audio files were downloaded
        local clientTestDlCount
        clientTestDlCount=$(find "${AUDIO_WORK_PATH}/staging" -type f \( -iname "*.flac" -o -iname "*.opus" -o -iname "*.m4a" -o -iname "*.mp3" \) | wc -l)
        if ((clientTestDlCount <= 0)); then
            log "WARNING :: No audio files downloaded for album \"${deezerAlbumTitle}\" on attempt #${downloadTry}"
            continue
        fi

        # Verify all downloaded FLAC files
        find "${AUDIO_WORK_PATH}/staging" -type f -iname "*.flac" -print0 |
            while IFS= read -r -d '' file; do
                if audioFlacVerification "$file"; then
                    log "INFO :: File \"${file}\" passed FLAC verification"
                else
                    log "WARNING :: File \"${file}\" failed FLAC verification. Removing"
                    rm -f "$file"
                fi
            done

        # Check if full album downloaded
        local downloadedCount
        downloadedCount=$(find "${AUDIO_WORK_PATH}/staging" -type f \( -iname "*.flac" -o -iname "*.opus" -o -iname "*.m4a" -o -iname "*.mp3" \) | wc -l)
        if ((downloadedCount != deezerAlbumTrackCount)); then
            log "WARNING :: Album \"${deezerAlbumTitle}\" did not download expected number of tracks"
            sleep 1
            continue
        else
            break
        fi
    done

    # Consolidate files to a single folder and delete empty folders
    log "INFO :: Consolidating files to single folder"

    # Move all files from subdirectories to the staging root
    find "${AUDIO_WORK_PATH}/staging" -mindepth 2 -type f -print0 | while IFS= read -r -d '' f; do
        dest="${AUDIO_WORK_PATH}/staging/$(basename "$f")"

        # Handle potential name collisions
        if [[ -e "$dest" ]]; then
            base="$(basename "$f")"
            ext="${base##*.}"
            name="${base%.*}"
            dest="${AUDIO_WORK_PATH}/staging/${name}_$(date +%s%N).${ext}"
            log "WARN :: Renamed duplicate file $(basename "$f") -> $(basename "$dest")"
        fi

        mv "$f" "$dest"
        log "TRACE :: Moved $f -> $dest"
    done

    # Remove now-empty subdirectories
    find "${AUDIO_WORK_PATH}/staging" -type d -mindepth 1 -empty -delete 2>/dev/null

    local returnCode=0

    # Add the MusicBrainz album info to FLAC and MP3 files
    if [ "$returnCode" -eq 0 ]; then
        local lidarrAlbumData="$(get_state "lidarrAlbumData")"
        local lidarrAlbumTitle="$(jq -r ".title" <<<"${lidarrAlbumData}")"
        local lidarrAlbumForeignAlbumId="$(jq -r ".foreignAlbumId" <<<"${lidarrAlbumData}")"
        local downloadedLidarrReleaseInfo="$(get_state "downloadedLidarrReleaseInfo")"
        local lidarrReleaseForeignId="$(jq -r ".foreignReleaseId" <<<"${downloadedLidarrReleaseInfo}")"

        log "DEBUG :: Title='${lidarrAlbumTitle}' AlbumID='${lidarrReleaseForeignId}' ReleaseGroupID='${lidarrAlbumForeignAlbumId}'"
        shopt -s nullglob
        for file in "${AUDIO_WORK_PATH}"/staging/*.{flac,mp3}; do
            [ -f "${file}" ] || continue
            log "DEBUG :: Tagging ${file}"

            case "${file##*.}" in
            flac)
                log "DEBUG :: Applying metaflac tags to: ${file}"
                metaflac --remove-tag=MUSICBRAINZ_ALBUMID \
                    --remove-tag=MUSICBRAINZ_RELEASEGROUPID \
                    --remove-tag=ALBUM \
                    --set-tag=MUSICBRAINZ_ALBUMID="${lidarrReleaseForeignId}" \
                    --set-tag=MUSICBRAINZ_RELEASEGROUPID="${lidarrAlbumForeignAlbumId}" \
                    --set-tag=ALBUM="${lidarrAlbumTitle}" "${file}"
                ;;
            mp3)
                log "DEBUG :: Applying mutagen tags to: ${file}"
                export ALBUM_TITLE="${lidarrAlbumTitle}"
                export MB_ALBUMID="${lidarrReleaseForeignId}"
                export MB_RELEASEGROUPID="${lidarrAlbumForeignAlbumId}"
                python3 python/MutagenTagger.py "${file}"
                ;;
            *)
                log "WARN :: Skipping unsupported format: ${file}"
                ;;
            esac
        done
        shopt -u nullglob
    fi

    # Add ReplayGain tags if enabled
    if [ "${returnCode}" -eq 0 ] && [ "${AUDIO_APPLY_REPLAYGAIN}" == "true" ]; then
        AddReplaygainTags "${AUDIO_WORK_PATH}/staging"
        returnCode=$?
        log "DEBUG :: returnCode=${returnCode}"
    else
        log "INFO :: Replaygain tagging disabled"
    fi

    # Add Beets tags if enabled
    if [ "${returnCode}" -eq 0 ] && [ "${AUDIO_APPLY_BEETS}" == "true" ]; then
        AddBeetsTags "${AUDIO_WORK_PATH}/staging"
        returnCode=$?
        log "DEBUG :: returnCode=${returnCode}"
    else
        log "INFO :: Beets tagging disabled"
    fi

    # Log Completed Download
    if [ "$returnCode" -eq 0 ]; then
        log "INFO :: Album \"${deezerAlbumTitle}\" successfully downloaded"
        touch "${AUDIO_DATA_PATH}/downloaded/${lidarrAlbumId}--${lidarrArtistForeignArtistId}--${lidarrAlbumForeignAlbumId}"

        local downloadedAlbumFolder="$(CleanPathString "${deezerArtistNameClean:0:100}")-$(CleanPathString "${deezerAlbumTitleClean:0:100}") (${downloadedReleaseYear})"
        mkdir -p "${AUDIO_SHARED_LIDARR_PATH}/${downloadedAlbumFolder}"
        find "${AUDIO_WORK_PATH}/staging" -type f -regex ".*/.*\.\(flac\|m4a\|mp3\|flac\|opus\)" -exec mv {} "${AUDIO_SHARED_LIDARR_PATH}/${downloadedAlbumFolder}"/ \;

        NotifyLidarrForImport "${AUDIO_SHARED_LIDARR_PATH}/${downloadedAlbumFolder}"
    else
        log "WARNING :: Album \"${deezerAlbumTitle}\" failed post-processing and was skipped"
    fi

    # Clean up staging folder
    rm -rf "${AUDIO_WORK_PATH}/staging"/*
    log "TRACE :: Exiting DownloadProcess..."
}

# Add ReplayGain tags to audio files in the specified folder using rsgain
AddReplaygainTags() {
    log "TRACE :: Entering AddReplaygainTags..."
    # $1 -> folder path containing audio files to be tagged
    local importPath="${1}"
    log "INFO :: Adding ReplayGain Tags using rsgain"

    local returnCode=0
    (
        set +e # temporarily disable -e in subshell
        rsgain easy --quiet "${importPath}"
    )
    returnCode=$? # capture exit code of subshell

    log "TRACE :: Exiting AddReplaygainTags..."
    return $returnCode
}

AddBeetsTags() {
    log "TRACE :: Entering AddBeetsTags..."
    # $1 -> folder path containing audio files to be tagged
    local importPath="${1}"
    log "INFO :: Adding Beets tags"

    # Setup
    rm -f ${BEETS_DIR}/beets-library.blb
    rm -f ${BEETS_DIR}/beets.log
    rm -f ${BEETS_DIR}/beets.timer
    touch ${BEETS_DIR}/beets-library.blb
    touch ${BEETS_DIR}/beets.timer

    local downloadedLidarrReleaseInfo="$(get_state "downloadedLidarrReleaseInfo")"
    local lidarrReleaseForeignId="$(jq -r ".foreignReleaseId" <<<"${downloadedLidarrReleaseInfo}")"

    local returnCode=0
    # Process with Beets
    (
        set +e # disable -e temporarily in subshell
        export XDG_CONFIG_HOME="${BEETS_DIR}/.config"
        export HOME="${BEETS_DIR}"
        mkdir -p "${XDG_CONFIG_HOME}"
        beet -c "${BEETS_DIR}/beets.yaml" \
            -l "${BEETS_DIR}/beets-library.blb" \
            -d "$1" import -qCw \
            -S "${lidarrReleaseForeignId}" \
            "$1"

        returnCode=$? # <- captures exit code of subshell
        if [ $returnCode -ne 0 ]; then
            log "WARNING :: Beets returned error code ${returnCode}"
        elif [ $(find "${importPath}" -type f -regex ".*/.*\.\(flac\|opus\|m4a\|mp3\)" -newer "${BEETS_DIR}/beets.timer" | wc -l) -gt 0 ]; then
            log "INFO :: Successfully added Beets tags"
        else
            log "WARNING :: Unable to match using beets to a musicbrainz release"
            returnCode=1
        fi
    )

    log "TRACE :: Exiting AddBeetsTags..."
    return ${returnCode}
}

# Verify a FLAC file for corruption
audioFlacVerification() {
    # $1 = path to FLAC file
    flac --totally-silent -t "$1" >/dev/null 2>&1
}

FormatPriority() {
    log "TRACE :: Entering FormatPriority..."
    # $1 -> Format string to evaluate
    local formatString="${1}"
    local priority=999 # Default low priority

    # Determine priority based on AUDIO_PREFERED_FORMATS
    # If AUDIO_PREFERED_FORMATS is blank, all formats are equal priority
    if [[ -z "${AUDIO_PREFERED_FORMATS}" ]]; then
        priority=0
    else
        IFS=',' read -r -a formatArray <<<"${AUDIO_PREFERED_FORMATS}"
        for i in "${!formatArray[@]}"; do
            if [[ "${formatString,,}" == *"${formatArray[$i],,}"* ]]; then
                priority=$i
                break
            fi
        done
    fi

    log "TRACE :: Exiting FormatPriority..."
    # Return calculated priority
    echo "${priority}"
}

CountriesPriority() {
    log "TRACE :: Entering CountriesPriority..."
    # $1 -> Countries string to evaluate (comma-separated)
    local countriesString="${1}"
    local priority=999 # Default low priority

    # Determine priority based on AUDIO_PREFERED_COUNTRIES
    # If AUDIO_PREFERED_COUNTRIES is blank, all countries are equal priority
    if [[ -z "${AUDIO_PREFERED_COUNTRIES}" ]]; then
        priority=0
    else
        IFS=',' read -r -a countryArray <<<"${AUDIO_PREFERED_COUNTRIES}"
        for i in "${!countryArray[@]}"; do
            if [[ "${countriesString,,}" == *"${countryArray[$i],,}"* ]]; then
                priority=$i
                break
            fi
        done
    fi

    log "TRACE :: Exiting CountriesPriority..."
    # Return calculated priority
    echo "${priority}"
}

###### Script Execution #####

### Preamble ###

log "INFO :: Starting ${scriptName}"

log "DEBUG :: AUDIO_APPLY_BEETS=${AUDIO_APPLY_BEETS}"
log "DEBUG :: AUDIO_APPLY_REPLAYGAIN=${AUDIO_APPLY_REPLAYGAIN}"
log "DEBUG :: AUDIO_CACHE_MAX_AGE_DAYS=${AUDIO_CACHE_MAX_AGE_DAYS}"
log "DEBUG :: AUDIO_BEETS_CUSTOM_CONFIG=${AUDIO_BEETS_CUSTOM_CONFIG}"
log "DEBUG :: AUDIO_COMMENTARY_KEYWORDS=${AUDIO_COMMENTARY_KEYWORDS}"
log "DEBUG :: AUDIO_DATA_PATH=${AUDIO_DATA_PATH}"
log "DEBUG :: AUDIO_DEEMIX_CUSTOM_CONFIG=${AUDIO_DEEMIX_CUSTOM_CONFIG}"
log "DEBUG :: AUDIO_DEEZER_API_RETRIES=${AUDIO_DEEZER_API_RETRIES}"
log "DEBUG :: AUDIO_DEEZER_API_TIMEOUT=${AUDIO_DEEZER_API_TIMEOUT}"
log "DEBUG :: AUDIO_DEEMIX_ARL_FILE=${AUDIO_DEEMIX_ARL_FILE}"
log "DEBUG :: AUDIO_DEPRIORITIZE_COMMENTARY_RELEASES=${AUDIO_DEPRIORITIZE_COMMENTARY_RELEASES}"
log "DEBUG :: AUDIO_DOWNLOADCLIENT_NAME=${AUDIO_DOWNLOADCLIENT_NAME}"
log "DEBUG :: AUDIO_DOWNLOAD_ATTEMPT_THRESHOLD=${AUDIO_DOWNLOAD_ATTEMPT_THRESHOLD}"
log "DEBUG :: AUDIO_DOWNLOAD_CLIENT_TIMEOUT=${AUDIO_DOWNLOAD_CLIENT_TIMEOUT}"
log "DEBUG :: AUDIO_FAILED_ATTEMPT_THRESHOLD=${AUDIO_FAILED_ATTEMPT_THRESHOLD}"
log "DEBUG :: AUDIO_IGNORE_INSTRUMENTAL_RELEASES=${AUDIO_IGNORE_INSTRUMENTAL_RELEASES}"
log "DEBUG :: AUDIO_INSTRUMENTAL_KEYWORDS=${AUDIO_INSTRUMENTAL_KEYWORDS}"
log "DEBUG :: AUDIO_INTERVAL=${AUDIO_INTERVAL}"
log "DEBUG :: AUDIO_LYRIC_TYPE=${AUDIO_LYRIC_TYPE}"
log "DEBUG :: AUDIO_MATCH_DISTANCE_THRESHOLD=${AUDIO_MATCH_DISTANCE_THRESHOLD}"
log "DEBUG :: AUDIO_PREFERED_COUNTRIES=${AUDIO_PREFERED_COUNTRIES}"
log "DEBUG :: AUDIO_PREFERED_FORMATS=${AUDIO_PREFERED_FORMATS}"
log "DEBUG :: AUDIO_REQUIRE_QUALITY=${AUDIO_REQUIRE_QUALITY}"
log "DEBUG :: AUDIO_RETRY_DOWNLOADED_DAYS=${AUDIO_RETRY_DOWNLOADED_DAYS}"
log "DEBUG :: AUDIO_RETRY_FAILED_DAYS=${AUDIO_RETRY_FAILED_DAYS}"
log "DEBUG :: AUDIO_RETRY_NOTFOUND_DAYS=${AUDIO_RETRY_NOTFOUND_DAYS}"
log "DEBUG :: AUDIO_SHARED_LIDARR_PATH=${AUDIO_SHARED_LIDARR_PATH}"
log "DEBUG :: AUDIO_TITLE_REPLACEMENTS_FILE=${AUDIO_TITLE_REPLACEMENTS_FILE}"
log "DEBUG :: AUDIO_WORK_PATH=${AUDIO_WORK_PATH}"

### Validation ###

# Nothing to validate

### Main ###

# Initalize state object
init_state

# Verify Lidarr API access
verifyArrApiAccess

# Create Lidarr entities
AddLidarrDownloadClient

# Setup Deemix & Beets
SetupDeemix
SetupBeets

log "INFO :: Lift off in..."
sleep 0.5
log "INFO :: 5"
sleep 1
log "INFO :: 4"
sleep 1
log "INFO :: 3"
sleep 1
log "INFO :: 2"
sleep 1
log "INFO :: 1"
sleep 1
while true; do
    # Cleanup old markers for albums previously marked as not found or downloaded
    FolderCleaner

    ProcessLidarrWantedList "missing"
    ProcessLidarrWantedList "cutoff"

    log "INFO :: Script sleeping for ${AUDIO_INTERVAL}..."
    sleep ${AUDIO_INTERVAL}
done

exit 0
