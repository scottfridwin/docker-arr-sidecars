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
    log "DEBUG :: Calculating Levenshtein distance between '${s1}' and '${s2}'"
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

# Fetch Deezer album info with caching and retries
GetDeezerAlbumInfo() {
    log "TRACE :: Entering GetDeezerAlbumInfo..."
    # $1 -> Deezer Album ID
    local albumId="$1"
    local retries=0
    local maxRetries="${AUDIO_DEEZER_API_RETRIES}"
    local albumCacheFile="${AUDIO_WORK_PATH}/cache/album-${albumId}.json"
    local albumJson
    local returnCode=1

    # Ensure cache directory exists
    mkdir -p "${AUDIO_WORK_PATH}/cache"

    while ((retries < maxRetries)); do
        # Fetch from Deezer if cache is missing
        if [ ! -f "${albumCacheFile}" ]; then
            # Curl with HTTP code capture
            httpCode=$(curl -sS -w "%{http_code}" -o "${albumCacheFile}" \
                --connect-timeout 5 --max-time ${AUDIO_DEEZER_API_TIMEOUT} \
                "https://api.deezer.com/album/${albumId}")

            if [[ "${httpCode}" -ne 200 ]]; then
                log "WARNING :: Deezer returned HTTP ${httpCode} for album ${albumId}, retrying..."
                rm -f "${albumCacheFile}"
                ((retries++))
                sleep 1
                continue
            fi
        fi

        # Validate JSON
        if albumJson=$(jq -e . <"${albumCacheFile}" 2>/dev/null); then
            #log "DEBUG :: albumJson: ${albumJson}"
            set_state "deezerAlbumInfo" "${albumJson}"
            returnCode=0
            break
        else
            log "WARNING :: Invalid JSON from Deezer for album ${albumId}, retrying... ($((retries + 1))/${maxRetries})"
            rm -f "${albumCacheFile}"
            ((retries++))
            sleep 1
        fi
    done

    if ((returnCode != 0)); then
        log "WARNING :: Failed to get valid album information after ${maxRetries} attempts for album ${albumId}"
    fi
    log "TRACE :: Exiting GetDeezerAlbumInfo..."
    return ${returnCode}
}

# Fetch Deezer artist's albums with caching and retries
GetDeezerArtistAlbums() {
    log "TRACE :: Entering GetDeezerArtistAlbums..."
    # $1 -> Deezer Artist ID
    local artistId="$1"
    local retries=0
    local maxRetries="${AUDIO_DEEZER_API_RETRIES}"
    local artistCacheFile="${AUDIO_WORK_PATH}/cache/artist-${artistId}-albums.json"
    local artistJson
    local httpCode
    local returnCode=1

    mkdir -p "${AUDIO_WORK_PATH}/cache"

    while ((retries < maxRetries)); do
        # Fetch from Deezer if cache is missing
        if [ ! -f "${artistCacheFile}" ]; then
            # Curl with HTTP code capture
            httpCode=$(curl -sS -w "%{http_code}" -o "${artistCacheFile}" \
                --connect-timeout 5 --max-time ${AUDIO_DEEZER_API_TIMEOUT} \
                "https://api.deezer.com/artist/${artistId}/albums?limit=1000")

            if [[ "${httpCode}" -ne 200 ]]; then
                log "WARNING :: Deezer returned HTTP ${httpCode} for artist ${artistId} albums, retrying..."
                rm -f "${artistCacheFile}"
                ((retries++))
                sleep 1
                continue
            fi
        fi

        # Validate JSON
        if artistJson=$(jq -e . <"${artistCacheFile}" 2>/dev/null); then
            #log "DEBUG :: artistJson: ${artistJson}"
            set_state "deezerArtistInfo" "${artistJson}"
            returnCode=0
            break
        else
            log "WARNING :: Invalid JSON for artist ${artistId} albums, retrying... ($((retries + 1))/${maxRetries})"
            rm -f "${artistCacheFile}"
            ((retries++))
            sleep 1
        fi
    done

    if ((returnCode != 0)); then
        log "WARNING :: Failed to get valid album list after ${maxRetries} attempts for artist ${artistId}"
    fi
    log "TRACE :: Exiting GetDeezerArtistAlbums..."
    return ${returnCode}
}

# Generic Deezer API call with retries and error handling
CallDeezerAPI() {
    log "TRACE :: Entering CallDeezerAPI..."
    # $1 -> Deezer API URL
    local url="${1}"
    local maxRetries="${AUDIO_DEEZER_API_RETRIES}"
    local retries=0
    local httpCode
    local body
    local response
    local returnCode=1

    while ((retries < maxRetries)); do
        # Capture HTTP code and output
        log "DEBUG :: url: ${url}"
        response=$(curl -s -w "\n%{http_code}" \
            --connect-timeout 5 \
            --max-time "${AUDIO_DEEZER_API_TIMEOUT}" \
            "${url}")

        httpCode=$(tail -n1 <<<"${response}")
        body=$(sed '$d' <<<"${response}")

        if [[ "${httpCode}" -eq 200 ]]; then
            #log "DEBUG :: body: ${body}"
            set_state "deezerApiResponse" "${body}"
            returnCode=0
            break
        else
            log "WARNING :: Deezer API returned HTTP ${httpCode:-<empty>} for URL ${url}, retrying ($((retries + 1))/${maxRetries})..."
            ((retries++))
            sleep 1
        fi
    done

    if ((returnCode != 0)); then
        log "WARNING :: Failed to get a valid response from Deezer API after ${maxRetries} attempts for URL ${url}"
    fi

    log "TRACE :: Exiting CallDeezerAPI..."
    return ${returnCode}
}

# Add custom tags if they don't already exist
AddLidarrTags() {
    log "TRACE :: Entering AddLidarrTags..."
    local response tagCheck httpCode

    # Fetch existing tags once
    ArrApiRequest "GET" "tag"
    response="$(get_state "arrApiResponse")"

    # Split comma-separated AUDIO_TAGS into array
    IFS=',' read -ra tags <<<"${AUDIO_TAGS}"

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
    log "TRACE :: Exiting AddLidarrTags..."
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

# Clean up old notfound entries to allow retries
NotFoundFolderCleaner() {
    log "TRACE :: Entering NotFoundFolderCleaner..."
    if [ -d "${AUDIO_DATA_PATH}/notfound" ]; then
        # check for notfound entries older than AUDIO_RETRY_NOTFOUND_DAYS days
        if find "${AUDIO_DATA_PATH}/notfound" -mindepth 1 -type f -mtime +${AUDIO_RETRY_NOTFOUND_DAYS} | read; then
            log "INFO :: Removing prevously notfound lidarr album ids older than ${AUDIO_RETRY_NOTFOUND_DAYS} days to give them a retry..."
            # delete notfound entries older than AUDIO_RETRY_NOTFOUND_DAYS days
            find "${AUDIO_DATA_PATH}/notfound" -mindepth 1 -type f -mtime +${AUDIO_RETRY_NOTFOUND_DAYS} -delete
        fi
    fi
    log "TRACE :: Exiting NotFoundFolderCleaner..."
}

# Given a MusicBrainz release JSON object, return the title with disambiguation if present
GetReleaseTitleDisambiguation() {
    log "TRACE :: Entering GetReleaseTitleDisambiguation..."
    # $1 -> JSON object for a MusicBrainz release
    local release_json="$1"
    local releaseTitle releaseDisambiguation
    releaseTitle=$(echo "$release_json" | jq -r '.title')
    releaseDisambiguation=$(echo "$release_json" | jq -r '.disambiguation')
    if [ -z "$releaseDisambiguation" ] || [ "$releaseDisambiguation" == "null" ]; then
        releaseDisambiguation=""
    else
        releaseDisambiguation=" ($releaseDisambiguation)"
    fi
    echo "${releaseTitle}${releaseDisambiguation}"
    log "TRACE :: Exiting GetReleaseTitleDisambiguation..."
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
    local defaultConfigFile="/app/config/deemix_config.json"
    if [[ ! -f "${defaultConfigFile}" ]]; then
        log "ERROR :: Default Deemix config not found at ${defaultConfigFile}"
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
    totalRecords=$(echo "$response" | jq -r .totalRecords)
    log "INFO :: Found ${totalRecords} ${listType} albums"

    if ((totalRecords < 1)); then
        log "INFO :: No ${listType} albums to process"
        return
    fi

    # Preload all notfound IDs into memory (only once)
    mapfile -t notfound < <(
        find "${AUDIO_DATA_PATH}/notfound/" -type f | while read -r f; do
            basename "$f"
        done | sed 's/--.*//' | sort
    )

    local totalPages=$(((totalRecords + pageSize - 1) / pageSize))

    for ((page = 1; page <= totalPages; page++)); do
        log "INFO :: Downloading page ${page} of ${totalPages} for ${listType} albums"

        # Fetch page of album IDs
        ArrApiRequest "GET" "wanted/${listType}?page=${page}&pagesize=${pageSize}&sortKey=${searchOrder}&sortDirection=${searchDirection}"
        local lidarrPage="$(get_state "arrApiResponse")"
        mapfile -t tocheck < <(
            jq -r '.records[].id // empty' <<<"$lidarrPage" | sort -u
        )

        # Filter out already failed/notfound IDs
        mapfile -t toProcess < <(comm -13 <(printf "%s\n" "${notfound[@]}") <(printf "%s\n" "${tocheck[@]}"))

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
    local wantedAlbumId="$1"
    if [ -z "$wantedAlbumId" ]; then
        log "WARNING :: No album ID provided to SearchProcess"
        return
    fi

    if [ ! -d "${AUDIO_DATA_PATH}/notfound" ]; then
        mkdir -p "${AUDIO_DATA_PATH}"/notfound
    fi

    # Fetch album data from Lidarr
    local lidarrAlbumData
    ArrApiRequest "GET" "album/${wantedAlbumId}"
    lidarrAlbumData="$(get_state "arrApiResponse")"
    if [ -z "$lidarrAlbumData" ]; then
        log "WARNING :: Lidarr returned no data for album ID ${wantedAlbumId}"
        return
    fi
    set_state "lidarrAlbumData" "${lidarrAlbumData}" # Cache response in state object

    # Extract artist and album info
    local lidarrArtistData lidarrArtistName lidarrArtistId lidarrArtistForeignArtistId
    lidarrArtistData=$(echo "$lidarrAlbumData" | jq -r ".artist")
    lidarrArtistName=$(echo "$lidarrArtistData" | jq -r ".artistName")
    lidarrArtistId=$(echo "$lidarrArtistData" | jq -r ".artistMetadataId")
    lidarrArtistForeignArtistId=$(echo "$lidarrArtistData" | jq -r ".foreignArtistId")
    set_state "lidarrArtistName" "${lidarrArtistName}"
    set_state "lidarrArtistId" "${lidarrArtistId}"
    set_state "lidarrArtistForeignArtistId" "${lidarrArtistForeignArtistId}"

    local lidarrAlbumTitle lidarrAlbumType lidarrAlbumForeignAlbumId
    lidarrAlbumTitle=$(echo "$lidarrAlbumData" | jq -r ".title")
    lidarrAlbumType=$(echo "$lidarrAlbumData" | jq -r ".albumType")
    lidarrAlbumForeignAlbumId=$(echo "$lidarrAlbumData" | jq -r ".foreignAlbumId")

    # Check if album was previously marked "not found"
    if [ -f "${AUDIO_DATA_PATH}/notfound/${wantedAlbumId}--${lidarrArtistForeignArtistId}--${lidarrAlbumForeignAlbumId}" ]; then
        log "INFO :: Album \"${lidarrAlbumTitle}\" by artist \"${lidarrArtistName}\" was previously marked as not found, skipping..."
        return
    fi

    # Release date check
    local releaseDate releaseDateClean currentDateClean albumIsNewRelease
    releaseDate=$(echo "${lidarrAlbumData}" | jq -r ".releaseDate")
    releaseDate=${releaseDate:0:10}                                  # YYYY-MM-DD
    releaseDateClean=$(echo "${releaseDate}" | sed -e 's/[^0-9]//g') # YYYYMMDD

    currentDateClean=$(date "+%Y%m%d")
    albumIsNewRelease="false"
    if [[ "${currentDateClean}" -lt "${releaseDateClean}" ]]; then
        log "INFO :: Album \"${lidarrAlbumTitle}\" by artist \"${lidarrArtistName}\" has not been released yet (${releaseDate}), skipping..."
        return
    elif ((currentDateClean - releaseDateClean < 8)); then
        albumIsNewRelease="true"
    fi

    log "INFO :: Starting search for album \"${lidarrAlbumTitle}\" by artist \"${lidarrArtistName}\""

    # Extract artist links
    local deezerArtistUrl=$(echo "${lidarrArtistData}" | jq -r '.links[]? | select(.name=="deezer") | .url')
    if [ -z "${deezerArtistUrl}" ]; then
        log "WARNING :: Missing Deezer link for artist ${lidarrArtistName}, skipping..."
        return
    fi
    local deezerArtistIds=($(echo "${deezerArtistUrl}" | grep -Eo '[[:digit:]]+' | sort -u))

    # Sort releases based on preference for special editions
    # Sort parameter explanations:
    #  - Track count (descending)
    #  - Rank (0 for preferred editions, 1 for others)
    #  - Title length (ascending if prefer special editions, descending if not)

    jq_filter_special="[.releases[]
	| .normalized_title = (.title | ascii_downcase)
	| .title_length = (.title | length)
	| .rank = (if (.normalized_title | test(\"deluxe|expanded|special|remaster\")) then 0 else 1 end)
	] | sort_by(-.trackCount, .rank, -.title_length)"

    jq_filter_normal="[.releases[]
	| .normalized_title = (.title | ascii_downcase)
	| .title_length = (.title | length)
	| .rank = (if (.normalized_title | test(\"deluxe|expanded|special|remaster\")) then 1 else 0 end)
	] | sort_by(-.trackCount, .rank, .title_length)"

    local sorted_releases
    if [ "${AUDIO_PREFER_SPECIAL_EDITIONS}" == "true" ]; then
        sorted_releases=$(echo "${lidarrAlbumData}" | jq -c "${jq_filter_special}")
    else
        sorted_releases=$(echo "${lidarrAlbumData}" | jq -c "${jq_filter_normal}")
    fi

    # Determine lyric filter for first pass
    local lyricFilter=()
    case "${AUDIO_LYRIC_TYPE}" in
    require-explicit)
        lyricFilter=("Explicit")
        ;;
    require-clean)
        lyricFilter=("Clean")
        ;;
    prefer-explicit)
        lyricFilter=("Explicit" "Clean")
        ;;
    prefer-clean)
        lyricFilter=("Clean" "Explicit")
        ;;
    *)
        log "WARNING :: Unknown AUDIO_LYRIC_TYPE='${AUDIO_LYRIC_TYPE}', defaulting to both"
        lyricFilter=("Explicit" "Clean")
        ;;
    esac

    # Reset search variables
    set_state "bestMatchID" ""
    set_state "bestMatchTitle" ""
    set_state "bestMatchYear" ""
    set_state "bestMatchDistance" 9999
    set_state "bestMatchTrackDiff" 9999
    set_state "bestMatchContainsCommentary" "false"
    set_state "perfectMatchFound" "false"

    # Load title replacement file
    if [[ -f "${AUDIO_TITLE_REPLACEMENTS_FILE}" ]]; then
        log "DEBUG :: Loading custom title replacements from ${AUDIO_TITLE_REPLACEMENTS_FILE}"
        while IFS="=" read -r key value; do
            key="$(normalize_string "$key")"
            value="$(normalize_string "$value")"
            set_state "titleReplacement_${key}" "$value"
        done < <(
            jq -r 'to_entries[] | "\(.key)=\(.value)"' "${AUDIO_TITLE_REPLACEMENTS_FILE}" 2>/dev/null
        )
    else
        log "DEBUG :: No custom title replacements file found (${AUDIO_TITLE_REPLACEMENTS_FILE})"
    fi

    # Start search loop
    local perfectMatchFound="false"
    for lyricType in "${lyricFilter[@]}"; do
        log "INFO :: Searching with lyric filter: ${lyricType}"

        # Process each release from Lidarr in sorted order
        local releases
        mapfile -t releasesArray < <(jq -c '.[]' <<<"$sorted_releases")
        for release_json in "${releasesArray[@]}"; do
            lidarrReleaseTitle=$(GetReleaseTitleDisambiguation "${release_json}")
            lidarrReleaseTrackCount="$(jq -r ".trackCount" <<<"${release_json}")"
            lidarrReleaseForeignId="$(jq -r ".foreignReleaseId" <<<"${release_json}")"
            set_state "lidarrReleaseInfo" "${release_json}"
            set_state "lidarrReleaseTitle" "${lidarrReleaseTitle}"
            set_state "lidarrReleaseTrackCount" "${lidarrReleaseTrackCount}"
            set_state "lidarrReleaseForeignId" "${lidarrReleaseForeignId}"

            # TODO: Enhance this functionality to intelligently handle releases that are expected to have these keywords
            # Ignore instrumental-like releases if configured
            if [[ "${AUDIO_IGNORE_INSTRUMENTAL_RELEASES}" == "true" ]]; then
                # Convert comma-separated list into an alternation pattern for Bash regex
                IFS=',' read -r -a keywordArray <<<"${AUDIO_INSTRUMENTAL_KEYWORDS}"
                keywordPattern="($(
                    IFS="|"
                    echo "${keywordArray[*]}"
                ))" # join array with | for pattern matching

                if [[ "${lidarrAlbumTitle}" =~ ${keywordPattern} ]]; then
                    log "INFO :: Album \"${lidarrAlbumTitle}\" matched instrumental keyword (${AUDIO_INSTRUMENTAL_KEYWORDS}), skipping..."
                    continue
                elif [[ "${lidarrReleaseTitle,,}" =~ ${keywordPattern,,} ]]; then
                    log "INFO :: Release \"${lidarrReleaseTitle}\" matched instrumental keyword (${AUDIO_INSTRUMENTAL_KEYWORDS}), skipping..."
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

            if [[ "${lidarrAlbumTitle,,}" =~ ${commentaryPattern,,} ]]; then
                log "DEBUG :: Album \"${lidarrAlbumTitle}\" matched commentary keyword (${AUDIO_COMMENTARY_KEYWORDS})"
                lidarrReleaseContainsCommentary="true"
            elif [[ "${lidarrReleaseTitle,,}" =~ ${commentaryPattern,,} ]]; then
                log "DEBUG :: Release \"${lidarrReleaseTitle}\" matched commentary keyword (${AUDIO_COMMENTARY_KEYWORDS})"
                lidarrReleaseContainsCommentary="true"
            fi
            set_state "lidarrReleaseContainsCommentary" "${lidarrReleaseContainsCommentary}"

            # Optionally de-prioritize releases that contain commentary tracks
            bestMatchContainsCommentary=$(get_state "bestMatchContainsCommentary")
            if [[ "${AUDIO_DEPRIORITIZE_COMMENTARY_RELEASES}" == "true" && "${lidarrReleaseContainsCommentary}" == "true" && "${bestMatchContainsCommentary}" == "false" ]]; then
                log "INFO :: Already found a match without commentary. Skipping commentary album ${lidarrReleaseTitle}"
                continue
            fi

            # First search through the artist's Deezer albums to find a match on album title and track count
            log "DEBUG :: lidarrArtistForeignArtistId: ${lidarrArtistForeignArtistId}"
            if [ "${lidarrArtistForeignArtistId}" != "${VARIOUS_ARTIST_ID}" ]; then # Skip various artists
                perfectMatchFound="$(get_state "perfectMatchFound")"
                if [ "${perfectMatchFound}" == "false" ]; then
                    log "DEBUG :: deezerArtistIds: ${deezerArtistIds[*]}"
                    for dId in "${!deezerArtistIds[@]}"; do
                        local deezerArtistId="${deezerArtistIds[$dId]}"
                        ArtistDeezerSearch "${lyricType}" "${deezerArtistId}"
                    done
                fi
            fi

            # Fuzzy search
            perfectMatchFound="$(get_state "perfectMatchFound")"
            if [ "${perfectMatchFound}" == "false" ]; then
                FuzzyDeezerSearch "${lyricType}"
            fi

            # End search if a perfect match was found
            perfectMatchFound="$(get_state "perfectMatchFound")"
            if [ "${perfectMatchFound}" == "true" ]; then
                break
            fi
        done

        # End search if a perfect match was found
        perfectMatchFound="$(get_state "perfectMatchFound")"
        if [ "${perfectMatchFound}" == "true" ]; then
            break
        fi
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
            if [ ! -f "${AUDIO_DATA_PATH}/notfound/${wantedAlbumId}--${lidarrArtistForeignArtistId}--${lidarrAlbumForeignAlbumId}" ]; then
                touch "${AUDIO_DATA_PATH}/notfound/${wantedAlbumId}--${lidarrArtistForeignArtistId}--${lidarrAlbumForeignAlbumId}"
            fi
        fi
    fi

    log "TRACE :: Exiting SearchProcess..."
}

# Search Deezer artist's albums for matches
ArtistDeezerSearch() {
    log "TRACE :: Entering ArtistDeezerSearch..."
    # $1 -> Lyric Type ("Clean" or "Explicit")
    # $2 -> Deezer Artist ID
    local lyricType="${1}"
    local artistId="${2}"

    local explicitFilter="false"
    if [[ "${lyricType}" == "Explicit" ]]; then
        explicitFilter="true"
    fi

    log "INFO :: Artist searching..."

    # Get Deezer artist album list
    local artistAlbums filteredAlbums resultsCount
    GetDeezerArtistAlbums "${artistId}"
    local returnCode=$?
    if [ "$returnCode" -eq 0 ]; then
        artistAlbums="$(get_state "deezerArtistInfo")"
        # Filter albums by lyric type (true/false for explicit_lyrics)
        filteredAlbums=$(jq -c ".data | map(select(.explicit_lyrics == ${explicitFilter}))" <<<"${artistAlbums}")

        resultsCount=$(jq 'length' <<<"${filteredAlbums}")
        log "INFO :: Searching albums for Artist ${artistId} filtered by ${lyricType} lyrics (Total Albums: ${resultsCount} found)"

        # Pass filtered albums to the CalculateBestMatch function
        if ((resultsCount > 0)); then
            CalculateBestMatch <<<"${filteredAlbums}"
        fi
    else
        log "WARNING :: Failed to fetch album list for Deezer artist ID ${artistId}"
    fi
    log "TRACE :: Exiting ArtistDeezerSearch..."
}

# Fuzzy search Deezer for albums matching title and artist
FuzzyDeezerSearch() {
    log "TRACE :: Entering FuzzyDeezerSearch..."
    # $1 -> Lyric Type ("true" = explicit, "false" = clean)

    local lyricFlag="${1}"
    local type
    local deezerSearch
    local resultsCount
    local albumsJson
    local url

    if [[ "${lyricFlag}" == "true" ]]; then
        type="Explicit"
    else
        type="Clean"
    fi

    local lidarrAlbumData="$(get_state "lidarrAlbumData")"
    local lidarrReleaseTitle="$(get_state "lidarrReleaseTitle")"
    local lidarrArtistForeignArtistId="$(get_state "lidarrArtistForeignArtistId")"
    local lidarrArtistName="$(get_state "lidarrArtistName")"

    log "INFO :: Fuzzy searching for '${lidarrReleaseTitle}' by '${lidarrArtistName}' (${type} lyrics)..."

    # Prepare search terms
    local albumTitleSearch albumArtistNameSearch lidarrAlbumReleaseTitleSearchClean lidarrArtistNameSearchClean
    lidarrAlbumReleaseTitleSearchClean="$(normalize_string "${lidarrReleaseTitle}")"
    lidarrArtistNameSearchClean="$(normalize_string "${lidarrArtistName}")"
    albumTitleSearch="$(jq -R -r @uri <<<"${lidarrAlbumReleaseTitleSearchClean}")"
    albumArtistNameSearch="$(jq -R -r @uri <<<"${lidarrArtistNameSearchClean}")"

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
            log "DEBUG :: ${resultsCount} search results found for '${lidarrReleaseTitle}' by '${lidarrArtistName}'"
            if ((resultsCount > 0)); then
                albumsJson=$(jq '[.data[].album] | unique_by(.id)' <<<"${deezerSearch}")
                uniqueResults=$(jq 'length' <<<"${albumsJson}")
                log "INFO :: ${uniqueResults} unique search results found for '${lidarrReleaseTitle}' by '${lidarrArtistName}'"
                CalculateBestMatch <<<"${albumsJson}"
            else
                log "INFO :: No results found via Fuzzy Search for '${lidarrReleaseTitle}' by '${lidarrArtistName}'"
            fi
        else
            log "WARNING :: Deezer Fuzzy Search API response missing expected fields"
        fi
    else
        log "WARNING :: Deezer Fuzzy Search failed for '${lidarrReleaseTitle}' by '${lidarrArtistName}'"
    fi
    log "TRACE :: Exiting FuzzyDeezerSearch..."
}

# Given a JSON array of Deezer albums, find the best match based on title similarity and track count
CalculateBestMatch() {
    log "TRACE :: Entering CalculateBestMatch..."
    # stdin -> JSON array containing list of Deezer albums to check

    local albums albumsCount
    albums=$(cat) # read JSON array from stdin
    albumsCount=$(jq 'length' <<<"${albums}")

    local bestMatchID="$(get_state "bestMatchID")"
    local bestMatchTitle="$(get_state "bestMatchTitle")"
    local bestMatchYear="$(get_state "bestMatchYear")"
    local bestMatchDistance="$(get_state "bestMatchDistance")"
    local bestMatchTrackDiff="$(get_state "bestMatchTrackDiff")"
    local bestMatchContainsCommentary="$(get_state "bestMatchContainsCommentary")"

    local lidarrReleaseTrackCount="$(get_state "lidarrReleaseTrackCount")"
    local lidarrReleaseTitle="$(get_state "lidarrReleaseTitle")"
    local lidarrReleaseContainsCommentary="$(get_state "lidarrReleaseContainsCommentary")"
    # Normalize Lidarr release title
    local lidarrReleaseTitleClean
    lidarrReleaseTitleClean="$(normalize_string "${lidarrReleaseTitle}")"
    lidarrReleaseTitleClean="${lidarrReleaseTitleClean:0:130}"

    for ((i = 0; i < albumsCount; i++)); do
        local deezerAlbumData deezerAlbumID deezerAlbumTitle deezerAlbumTitleClean
        local deezerAlbumTrackCount downloadedReleaseDate downloadedReleaseYear
        local diff trackDiff

        deezerAlbumData=$(jq -c ".[$i]" <<<"${albums}")
        deezerAlbumID=$(jq -r ".id" <<<"${deezerAlbumData}")
        deezerAlbumTitle=$(jq -r ".title" <<<"${deezerAlbumData}")

        # --- Normalize title ---
        deezerAlbumTitleClean="$(normalize_string "$deezerAlbumTitle")"
        deezerAlbumTitleClean="${deezerAlbumTitleClean:0:130}"
        # TODO - In some cases, albums have strange translations that need to happen for comparison to work.
        #Example: For Taylor Swift's 1989, Deezer has "1989 (Deluxe Edition)" but musicbrainz has "1989 D.L.X." because that is the title on the album

        # Apply custom replacements if defined
        replacement="$(get_state "titleReplacement_${deezerAlbumTitleClean}")"
        if [[ -n "$replacement" ]]; then
            log "DEBUG :: Title matched replacement rule: \"${deezerAlbumTitleClean}\" → \"${replacement}\""
            deezerAlbumTitleClean="${replacement}"
        fi

        # Get album info from Deezer
        GetDeezerAlbumInfo "${deezerAlbumID}"
        local returnCode=$?
        if [ "$returnCode" -eq 0 ]; then
            deezerAlbumData="$(get_state "deezerAlbumInfo")"
            deezerAlbumTrackCount=$(jq -r .nb_tracks <<<"${deezerAlbumData}")
            downloadedReleaseDate=$(jq -r .release_date <<<"${deezerAlbumData}")
            downloadedReleaseYear="${downloadedReleaseDate:0:4}"
        else
            log "WARNING :: Failed to fetch album info for Deezer album ID ${deezerAlbumID}, skipping..."
            continue
        fi

        # Compute Levenshtein distance
        diff=$(LevenshteinDistance "${lidarrReleaseTitleClean,,}" "${deezerAlbumTitleClean,,}")
        trackDiff=$((lidarrReleaseTrackCount > deezerAlbumTrackCount ? lidarrReleaseTrackCount - deezerAlbumTrackCount : deezerAlbumTrackCount - lidarrReleaseTrackCount))

        log "DEBUG :: DL Dist=${diff} TrackDiff=${trackDiff} (${deezerAlbumTrackCount} tracks)"

        if ((diff <= ${AUDIO_MATCH_DISTANCE_THRESHOLD})); then
            log "INFO :: Potential match found :: ${deezerAlbumTitle} (${downloadedReleaseYear}) :: Distance=${diff} TrackDiff=${trackDiff}"
        else
            log "DEBUG :: Album does not meet matching threshold, skipping..."
            continue
        fi

        # Perfect match
        if ((diff == 0 && trackDiff == 0)); then
            bestMatchID="${deezerAlbumID}"
            bestMatchTitle="${deezerAlbumTitle}"
            bestMatchYear="${downloadedReleaseYear}"
            bestMatchDistance="${diff}"
            bestMatchTrackDiff="${trackDiff}"
            set_state "bestMatchID" "${bestMatchID}"
            set_state "bestMatchTitle" "${bestMatchTitle}"
            set_state "bestMatchYear" "${bestMatchYear}"
            set_state "bestMatchDistance" "${bestMatchDistance}"
            set_state "bestMatchTrackDiff" "${bestMatchTrackDiff}"
            set_state "bestMatchContainsCommentary" "${lidarrReleaseContainsCommentary}"
            set_state "perfectMatchFound" "true"
            log "INFO :: Perfect match found :: ${bestMatchTitle} (${bestMatchYear})"
            break
        fi

        # Track best match so far
        if ((diff < bestMatchDistance)) || ((diff == bestMatchDistance && trackDiff < bestMatchTrackDiff)); then
            bestMatchID="${deezerAlbumID}"
            bestMatchTitle="${deezerAlbumTitle}"
            bestMatchYear="${downloadedReleaseYear}"
            bestMatchDistance="${diff}"
            bestMatchTrackDiff="${trackDiff}"
            set_state "bestMatchID" "${bestMatchID}"
            set_state "bestMatchTitle" "${bestMatchTitle}"
            set_state "bestMatchYear" "${bestMatchYear}"
            set_state "bestMatchDistance" "${bestMatchDistance}"
            set_state "bestMatchTrackDiff" "${bestMatchTrackDiff}"
            set_state "bestMatchContainsCommentary" "${lidarrReleaseContainsCommentary}"
        fi
    done

    log "TRACE :: Exiting CalculateBestMatch..."
}

# Given a JSON array of Deezer albums, find the best match based on title similarity and track count
DownloadBestMatch() {
    log "TRACE :: Entering DownloadBestMatch..."

    local bestMatchID="$(get_state "bestMatchID")"
    local bestMatchTitle="$(get_state "bestMatchTitle")"
    local bestMatchYear="$(get_state "bestMatchYear")"
    local bestMatchDistance="$(get_state "bestMatchDistance")"
    local bestMatchTrackDiff="$(get_state "bestMatchTrackDiff")"

    # Download the best match that was found
    log "INFO :: Using best match :: ${bestMatchTitle} (${bestMatchYear}) :: Distance=${bestMatchDistance} TrackDiff=${bestMatchTrackDiff}"

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
    deezerAlbumId=$(echo "${deezerAlbumJson}" | jq -r ".id")
    deezerAlbumTitle=$(echo "${deezerAlbumJson}" | jq -r ".title" | head -n1)
    deezerAlbumTitleClean=$(normalize_string "$deezerAlbumTitle")
    deezerAlbumTrackCount="$(echo "${deezerAlbumJson}" | jq -r .nb_tracks)"
    deezerArtistName=$(jq -r '.artist.name' <<<"${deezerAlbumJson}")
    deezerArtistNameClean=$(normalize_string "$deezerArtistName")
    downloadedReleaseDate=$(jq -r .release_date <<<"${deezerAlbumJson}")
    downloadedReleaseYear="${downloadedReleaseDate:0:4}"

    # Check if previously downloaded or failed download
    if [ -f "${AUDIO_DATA_PATH}/downloaded/${deezerAlbumId}" ]; then
        log "WARNING :: Album \"${deezerAlbumTitle}\" previously downloaded (${deezerAlbumId})...Skipping..."
        return
    fi
    if [ -f "${AUDIO_DATA_PATH}/failed/${deezerAlbumId}" ]; then
        log "WARNING :: Album \"${deezerAlbumTitle}\" previously failed to download ($deezerAlbumId)...Skipping..."
        return
    fi

    local downloadTry=0
    while true; do
        downloadTry=$(($downloadTry + 1))

        # Stop trying after too many attempts
        if ((downloadTry >= AUDIO_DOWNLOAD_ATTEMPT_THRESHOLD)); then
            log "WARNING :: Album \"${deezerAlbumTitle}\" failed to download after ${downloadTry} attempts...Skipping..."
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
    {
        shopt -s nullglob
        for f in "${AUDIO_WORK_PATH}"/staging/*/*; do
            mv "$f" "${AUDIO_WORK_PATH}/staging/"
        done
        shopt -u nullglob
    }
    # Remove now-empty subdirectories
    find "${AUDIO_WORK_PATH}/staging/" -type d -mindepth 1 -maxdepth 1 -exec rm -rf {} \; 2>/dev/null

    local returnCode=0
    # Add ReplayGain tags if enabled
    if [ "$returnCode" -eq 0 ] && [ "${AUDIO_APPLY_REPLAYGAIN}" == "true" ]; then
        AddReplaygainTags "${AUDIO_WORK_PATH}/staging"
        returnCode=$?
    else
        log "INFO :: Replaygain tagging disabled"
    fi

    # Add Beets tags if enabled
    if [ "$returnCode" -eq 0 ] && [ "${AUDIO_APPLY_BEETS}" == "true" ]; then
        AddBeetsTags "${AUDIO_WORK_PATH}/staging"
        returnCode=$?
    else
        log "INFO :: Beets tagging disabled"
    fi

    # Add the musicbrainz album id to the files
    if [ "$returnCode" -eq 0 ]; then
        local lidarrAlbumData="$(get_state "lidarrAlbumData")"
        local lidarrAlbumTitle="$(jq -r ".title" <<<"${lidarrAlbumData}")"
        local lidarrAlbumForeignAlbumId="$(jq -r ".foreignAlbumId" <<<"${lidarrAlbumData}")"
        local lidarrReleaseInfo="$(get_state "lidarrReleaseInfo")"
        local lidarrReleaseForeignId="$(jq -r ".foreignReleaseId" <<<"${lidarrReleaseInfo}")"
        shopt -s nullglob
        for file in "${AUDIO_WORK_PATH}"/staging/*.{flac,mp3,m4a,ogg,opus,wav}; do
            [ -f "$file" ] || continue
            log "DEBUG :: Tagging $file"
            case "${file##*.}" in
            flac)
                metaflac --remove-tag=MUSICBRAINZ_ALBUMID \
                    --remove-tag=MUSICBRAINZ_RELEASEGROUPID \
                    --remove-tag=ALBUM \
                    --set-tag=MUSICBRAINZ_ALBUMID="$lidarrReleaseForeignId" \
                    --set-tag=MUSICBRAINZ_RELEASEGROUPID="$lidarrAlbumForeignAlbumId" \
                    --set-tag=ALBUM="$lidarrAlbumTitle" "$file"
                ;;
            mp3)
                id3v2 --delete-frames "TXXX:MUSICBRAINZ_ALBUMID" \
                    --delete-frames "TXXX:MUSICBRAINZ_RELEASEGROUPID" \
                    --TXXX "MUSICBRAINZ_ALBUMID:$lidarrReleaseForeignId" \
                    --TXXX "MUSICBRAINZ_RELEASEGROUPID:$lidarrAlbumForeignAlbumId" \
                    --album "$lidarrAlbumTitle" "$file"
                ;;
            *)
                log "WARN :: Unknown format: $file"
                ;;
            esac
        done
        shopt -u nullglob
    fi

    # Log Completed Download
    if [ "$returnCode" -eq 0 ]; then
        log "INFO :: Album \"${deezerAlbumTitle}\" successfully downloaded"
        touch "${AUDIO_DATA_PATH}/downloaded/${deezerAlbumId}"

        local downloadedAlbumFolder="${deezerArtistNameClean}-${deezerAlbumTitleClean:0:100} (${downloadedReleaseYear})"
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

# Add ReplayGain tags to audio files in the specified folder
#TODO: replace with rsgain
AddReplaygainTags() {
    log "TRACE :: Entering AddReplaygainTags..."
    # $1 -> folder path containing audio files to be tagged
    log "INFO :: Adding ReplayGain Tags using r128gain"
    local importPath="${1}"

    local returnCode=0
    (
        set +e # disable -e temporarily in subshell
        r128gain -r -c 1 -a "${importPath}" >/dev/null 2>/tmp/r128gain_errors.log
    )
    returnCode=$? # <- captures exit code of subshell
    if [ $returnCode -ne 0 ]; then
        log "WARNING :: r128gain encountered errors while processing $1. See /tmp/r128gain_errors.log for details."
    fi

    rm -f /tmp/r128gain_errors.log
    log "TRACE :: Exiting AddReplaygainTags..."
    return ${returnCode}
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

    local returnCode=0
    # Process with Beets
    (
        set +e # disable -e temporarily in subshell
        export XDG_CONFIG_HOME="${BEETS_DIR}/.config"
        export HOME="${BEETS_DIR}"
        mkdir -p "${XDG_CONFIG_HOME}"
        beet -c "${BEETS_DIR}/beets.yaml" \
            -l "${BEETS_DIR}/beets-library.blb" \
            -d "$1" import -qC "$1"

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
log "DEBUG :: AUDIO_PREFER_SPECIAL_EDITIONS=${AUDIO_PREFER_SPECIAL_EDITIONS}"
log "DEBUG :: AUDIO_REQUIRE_QUALITY=${AUDIO_REQUIRE_QUALITY}"
log "DEBUG :: AUDIO_RETRY_NOTFOUND_DAYS=${AUDIO_RETRY_NOTFOUND_DAYS}"
log "DEBUG :: AUDIO_SHARED_LIDARR_PATH=${AUDIO_SHARED_LIDARR_PATH}"
log "DEBUG :: AUDIO_TAGS=${AUDIO_TAGS}"
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
AddLidarrTags
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
    # Cleanup old markers for albums previously marked as not found
    NotFoundFolderCleaner

    ProcessLidarrWantedList "missing"
    ProcessLidarrWantedList "cutoff"

    log "INFO :: Script sleeping for ${AUDIO_INTERVAL}..."
    sleep ${AUDIO_INTERVAL}
done

exit 0
