#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail

### Script values
scriptName="DeemixDownloader"

#### Imports
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../utilities.sh"
source "${SCRIPT_DIR}/functions.bash"

#### Constants
readonly VARIOUS_ARTIST_ID_MUSICBRAINZ="89ad4ac3-39f7-470e-963a-56509c546377"
readonly VARIOUS_ARTIST_ID_DEEZER="5080"
readonly DEEMIX_DIR="/tmp/deemix"
readonly DEEMIX_CONFIG_PATH="${DEEMIX_DIR}/config/config.json"
readonly BEETS_DIR="/tmp/beets"
readonly BEETS_CONFIG_PATH="${BEETS_DIR}/beets.yaml"

# Generic Deezer API call with retries and error handling
CallDeezerAPI() {
    log "TRACE :: Entering CallDeezerAPI..."
    local url="${1}"
    local maxRetries="${AUDIO_DEEZER_API_RETRIES:-3}"
    local retries=0
    local httpCode body response curlExit returnCode=1

    while ((retries < maxRetries)); do
        log "DEBUG :: Calling Deezer api: ${url}"

        # Run curl and capture output + HTTP code
        response="$(curl -sS -w '\n%{http_code}' \
            --connect-timeout 5 \
            --max-time "${AUDIO_DEEZER_API_TIMEOUT:-10}" \
            "${url}" 2>/dev/null || true)"
        curlExit=$?

        if [[ $curlExit -ne 0 || -z "$response" ]]; then
            log "WARNING :: curl failed (exit $curlExit) for URL ${url}, retrying ($((retries + 1))/${maxRetries})..."
            retries=$((retries + 1))
            sleep 1
            continue
        fi

        # Split body and HTTP code
        httpCode=$(tail -n1 <<<"$response")
        body=$(sed '$d' <<<"$response")

        # Treat HTTP 000 as failure
        if [[ -z "$httpCode" || "$httpCode" == "000" || "$httpCode" == "0" ]]; then
            log "WARNING :: No HTTP response (000) from Deezer API for URL ${url}, retrying ($((retries + 1))/${maxRetries})..."
            retries=$((retries + 1))
            sleep 1
            continue
        fi

        # Check for success
        if [[ "$httpCode" -eq 200 && -n "$body" ]]; then
            # Validate JSON safely
            if safe_jq --optional '.' <<<"$body" >/dev/null; then
                set_state "deezerApiResponse" "$body"
                returnCode=0
                break
            else
                log "WARNING :: Invalid JSON body from Deezer API for URL ${url}, retrying ($((retries + 1))/${maxRetries})..."
            fi
        else
            log "WARNING :: Deezer API returned HTTP ${httpCode:-<empty>} for URL ${url}, retrying ($((retries + 1))/${maxRetries})..."
        fi

        retries=$((retries + 1))
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
    local albumCacheFile="${AUDIO_WORK_PATH}/cache/deezer-album-${albumId}.json"
    local albumJson=""

    mkdir -p "${AUDIO_WORK_PATH}/cache"

    # Load from cache if valid
    if [[ -f "${albumCacheFile}" ]]; then
        if safe_jq --optional '.' <"${albumCacheFile}" >/dev/null 2>&1; then
            log "DEBUG :: Using cached Deezer album data for ${albumId}"
            albumJson="$(<"${albumCacheFile}")"
        else
            log "WARNING :: Cached album JSON invalid, will refetch: ${albumCacheFile}"
        fi
    fi

    if [[ -z "$albumJson" ]]; then
        local apiUrl="https://api.deezer.com/album/${albumId}"
        if ! CallDeezerAPI "${apiUrl}"; then
            log "ERROR :: Failed to get album info for ${albumId}"
            setUnhealthy
            exit 1
        fi
        albumJson="$(get_state "deezerApiResponse")"

        # Determine if track pagination is needed
        local nb_tracks embedded_tracks
        nb_tracks="$(safe_jq '.nb_tracks' <<<"$albumJson")"
        embedded_tracks="$(safe_jq '.tracks.data | length' <<<"$albumJson")"

        if ((embedded_tracks < nb_tracks)); then
            log "DEBUG :: Album ${albumId} has ${nb_tracks} tracks, fetching remaining pages"

            local all_tracks=()
            local nextUrl="https://api.deezer.com/album/${albumId}/tracks"

            while [[ -n "$nextUrl" ]]; do
                if ! CallDeezerAPI "$nextUrl"; then
                    log "ERROR :: Failed fetching Deezer album tracks"
                    setUnhealthy
                    exit 1
                fi

                local page
                page="$(get_state "deezerApiResponse")"

                # Validate JSON
                if ! safe_jq '.' <<<"$page" >/dev/null 2>&1; then
                    log "ERROR :: Deezer returned invalid JSON for url ${nextUrl}"
                    log "ERROR :: Raw response (first 200 chars): ${page:0:200}"
                    setUnhealthy
                    exit 1
                fi

                mapfile -t page_tracks < <(
                    safe_jq -c '[.data[]]' <<<"$page"
                )

                all_tracks+=("${page_tracks[@]}")

                # Follow pagination
                nextUrl="$(safe_jq --optional '.next' <<<"$page")"

                [[ -n "$nextUrl" ]] && sleep 0.2
            done

            # Replace the json track data in the original result with the new full track list
            albumJson="$(
                printf '%s\n' "${all_tracks[@]}" |
                    safe_jq -s \
                        --argjson album "$albumJson" '
                            add as $tracks
                            | ($tracks | length) as $total
                            | $album
                            | .tracks.data = $tracks
                            | .tracks.total = $total
                        '
            )"
        fi
    fi

    echo "${albumJson}" >"${albumCacheFile}"
    set_state "deezerAlbumInfo" "${albumJson}"

    log "TRACE :: Exiting GetDeezerAlbumInfo..."
    return 0
}

# Fetch Deezer artist albums with caching (uses CallDeezerAPI)
GetDeezerArtistAlbums() {
    log "TRACE :: Entering GetDeezerArtistAlbums..."
    local artistId="$1"
    local artistCacheFile="${AUDIO_WORK_PATH}/cache/deezer-artist-${artistId}-albums.json"
    local artistJson=""

    mkdir -p "${AUDIO_WORK_PATH}/cache"

    # Use cache if exists and valid
    if [[ -f "${artistCacheFile}" ]]; then
        if safe_jq --optional '.' <"${artistCacheFile}" >/dev/null 2>&1; then
            log "DEBUG :: Using cached Deezer artist album list for ${artistId}"
            artistJson="$(<"${artistCacheFile}")"
        else
            log "WARNING :: Cached artist album JSON invalid, will refetch: ${artistCacheFile}"
        fi
    fi

    if [[ -z "$artistJson" ]]; then
        local all_albums=()
        local nextUrl="https://api.deezer.com/artist/${artistId}/albums?limit=100"

        while [[ -n "$nextUrl" ]]; do
            if ! CallDeezerAPI "$nextUrl"; then
                log "ERROR :: Failed calling Deezer artist albums endpoint"
                setUnhealthy
                exit 1
            fi

            local page
            page="$(get_state "deezerApiResponse")"

            # Validate JSON
            if ! safe_jq '.' <<<"$page" >/dev/null 2>&1; then
                log "ERROR :: Deezer returned invalid JSON for url ${nextUrl}"
                log "ERROR :: Raw response (first 200 chars): ${page:0:200}"
                setUnhealthy
                exit 1
            fi

            # Extract albums
            mapfile -t page_albums < <(
                safe_jq -c '[.data[]]' <<<"$page"
            )

            all_albums+=("${page_albums[@]}")

            # Follow pagination
            nextUrl="$(safe_jq --optional '.next' <<<"$page")"

            [[ -n "$nextUrl" ]] && sleep 0.2
        done

        artistJson="$(
            printf '%s\n' "${all_albums[@]}" | safe_jq -s '
        add as $arr
        | { total: ($arr | length), data: $arr }
    '
        )"
    fi

    echo "${artistJson}" >"${artistCacheFile}"
    set_state "deezerArtistInfo" "${artistJson}"

    log "TRACE :: Exiting GetDeezerArtistAlbums..."
    return 0
}

# Add custom download client if it doesn't already exist
AddDownloadClient() {
    log "TRACE :: Entering AddDownloadClient..."
    local downloadClientsData downloadClientCheck httpCode

    # Get list of existing download clients
    ArrApiRequest "GET" "downloadclient"
    downloadClientsData="$(get_state "arrApiResponse")"

    # Validate JSON response
    downloadClientsData="$(safe_jq --optional '.' <<<"${downloadClientsData}" || echo '{}')"

    # Check if our custom client already exists
    downloadClientExists="$(safe_jq --arg name "${AUDIO_DOWNLOADCLIENT_NAME}" '
        any(.[]; .name == $name)
    ' <<<"${downloadClientsData}")"

    if [[ "${downloadClientExists}" != "true" ]]; then
        log "DEBUG :: ${AUDIO_DOWNLOADCLIENT_NAME} client not found, creating it..."

        # Build JSON payload safely
        payload="$(
            jq -n \
                --arg name "${AUDIO_DOWNLOADCLIENT_NAME}" \
                --arg path "${AUDIO_SHARED_LIDARR_PATH}" \
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
        log "DEBUG :: Successfully added ${AUDIO_DOWNLOADCLIENT_NAME} download client."
    else
        log "DEBUG :: ${AUDIO_DOWNLOADCLIENT_NAME} download client already exists, skipping creation."
    fi

    log "TRACE :: Exiting AddDownloadClient..."
}

# Clean up old notfound or downloaded entries to allow retries
FolderCleaner() {
    log "TRACE :: Entering FolderCleaner..."
    if [ -d "${AUDIO_DATA_PATH}/notfound" ]; then
        # check for notfound entries older than AUDIO_RETRY_NOTFOUND_DAYS days
        if find "${AUDIO_DATA_PATH}/notfound" -mindepth 1 -type f -mtime +${AUDIO_RETRY_NOTFOUND_DAYS} | read; then
            log "DEBUG :: Removing prevously notfound lidarr album ids older than ${AUDIO_RETRY_NOTFOUND_DAYS} days to give them a retry..."
            # delete notfound entries older than AUDIO_RETRY_NOTFOUND_DAYS days
            find "${AUDIO_DATA_PATH}/notfound" -mindepth 1 -type f -mtime +${AUDIO_RETRY_NOTFOUND_DAYS} -delete
        fi
    fi
    if [ -d "${AUDIO_DATA_PATH}/downloaded" ]; then
        # check for downloaded entries older than AUDIO_RETRY_DOWNLOADED_DAYS days
        if find "${AUDIO_DATA_PATH}/downloaded" -mindepth 1 -type f -mtime +${AUDIO_RETRY_DOWNLOADED_DAYS} | read; then
            log "DEBUG :: Removing previously downloaded lidarr album ids older than ${AUDIO_RETRY_DOWNLOADED_DAYS} days to give them a retry..."
            # delete downloaded entries older than AUDIO_RETRY_DOWNLOADED_DAYS days
            find "${AUDIO_DATA_PATH}/downloaded" -mindepth 1 -type f -mtime +${AUDIO_RETRY_DOWNLOADED_DAYS} -delete
        fi
    fi
    if [ -d "${AUDIO_DATA_PATH}/failed" ]; then
        # check for failed entries older than AUDIO_RETRY_FAILED_DAYS days
        if find "${AUDIO_DATA_PATH}/failed" -mindepth 1 -type f -mtime +${AUDIO_RETRY_FAILED_DAYS} | read; then
            log "DEBUG :: Removing previously failed lidarr album ids older than ${AUDIO_RETRY_FAILED_DAYS} days to give them a retry..."
            # delete failed entries older than AUDIO_RETRY_FAILED_DAYS days
            find "${AUDIO_DATA_PATH}/failed" -mindepth 1 -type f -mtime +${AUDIO_RETRY_FAILED_DAYS} -delete
        fi
    fi
    log "TRACE :: Exiting FolderCleaner..."
}

# Notify Lidarr to import the downloaded album
NotifyLidarrForImport() {
    log "TRACE :: Entering NotifyLidarrForImport..."
    # $1 -> folder path containing audio files for Lidarr to import
    local importPath="${1}"

    ArrApiRequest "POST" "command" "{\"name\":\"DownloadedAlbumsScan\", \"path\":\"${importPath}\"}"

    log "DEBUG :: Sent notification to Lidarr to import downloaded album at path: ${importPath}"
    log "TRACE :: Exiting NotifyLidarrForImport..."
}

# Set up Deemix client configuration
SetupDeemix() {
    log "TRACE :: Entering SetupDeemix..."
    log "DEBUG :: Setting up Deemix client"

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
    if [[ -n "${FUNCTIONALTESTDIR:-}" ]]; then
        defaultConfigFile="$FUNCTIONALTESTDIR/../config/deemix_config.json"
    fi
    if [[ ! -f "${defaultConfigFile}" ]]; then
        log "ERROR :: Default Deemix config not found at ${defaultConfigFile}"
        setUnhealthy
        exit 1
    fi

    mkdir -p "${DEEMIX_DIR}/config"
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
        log "DEBUG :: Custom Deemix config merged into ${DEEMIX_CONFIG_PATH}"
    fi

    log "DEBUG :: Deemix client setup complete. ARL token stored in global DEEMIX_ARL variable."
    log "TRACE :: Exiting SetupDeemix..."
}

# Set up Deemix client configuration
SetupBeets() {
    log "TRACE :: Entering SetupBeets..."
    log "DEBUG :: Setting up Beets configuration"

    # Copy default config to /tmp
    local defaultConfigFile="/app/config/beets_config.yaml"
    if [[ -n "${FUNCTIONALTESTDIR:-}" ]]; then
        defaultConfigFile="$FUNCTIONALTESTDIR/../config/beets_config.yaml"
    fi
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
        log "DEBUG :: Custom Beets config merged into ${BEETS_CONFIG_PATH}"
    fi

    log "DEBUG :: Beets configuration complete"
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

    log "DEBUG :: Retrieving ${listType} albums from Lidarr"

    # Get total count of albums
    local response totalRecords
    ArrApiRequest "GET" "wanted/${listType}?page=1&pagesize=1&sortKey=${searchOrder}&sortDirection=${searchDirection}"
    response="$(get_state "arrApiResponse")"
    totalRecords=$(jq -r .totalRecords <<<"$response")
    log "DEBUG :: Found ${totalRecords} ${listType} albums"

    if ((totalRecords < 1)); then
        log "DEBUG :: No ${listType} albums to process"
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
        log "DEBUG :: Downloading page ${page} of ${totalPages} for ${listType} albums"

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
        log "DEBUG :: ${recordCount} ${listType} albums to process"

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
    # $1 -> Lidarr album ID
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

    ExtractArtistInfo "$(safe_jq '.artist' <<<"$lidarrAlbumData")"
    ExtractAlbumInfo "$(safe_jq '.' <<<"$lidarrAlbumData")"
    local lidarrArtistForeignArtistId=$(get_state "lidarrArtistForeignArtistId")
    local lidarrAlbumForeignAlbumId=$(get_state "lidarrAlbumForeignAlbumId")
    local lidarrArtistName=$(get_state "lidarrArtistName")
    local lidarrAlbumTitle=$(get_state "lidarrAlbumTitle")

    # Check if album was previously marked "not found"
    if [ -f "${AUDIO_DATA_PATH}/notfound/${lidarrAlbumId}--${lidarrArtistForeignArtistId}--${lidarrAlbumForeignAlbumId}" ]; then
        log "DEBUG :: Album \"${lidarrAlbumTitle}\" by artist \"${lidarrArtistName}\" was previously marked as not found, skipping..."
        return
    fi

    # Check if album was previously marked "downloaded"
    if [ -f "${AUDIO_DATA_PATH}/downloaded/${lidarrAlbumId}--${lidarrArtistForeignArtistId}--${lidarrAlbumForeignAlbumId}" ]; then
        log "DEBUG :: Album \"${lidarrAlbumTitle}\" by artist \"${lidarrArtistName}\" was previously marked as downloaded, skipping..."
        return
    fi

    # Release date check
    local albumIsNewRelease=false
    local lidarrAlbumReleaseDate=$(get_state "lidarrAlbumReleaseDate")
    local lidarrAlbumReleaseDateClean=$(get_state "lidarrAlbumReleaseDateClean")

    currentDateClean=$(date "+%Y%m%d")
    if [[ "${currentDateClean}" -lt "${lidarrAlbumReleaseDateClean}" ]]; then
        log "DEBUG :: Album \"${lidarrAlbumTitle}\" by artist \"${lidarrArtistName}\" has not been released yet (${lidarrAlbumReleaseDate}), skipping..."
        return
    elif ((currentDateClean - lidarrAlbumReleaseDateClean < 8)); then
        albumIsNewRelease=true
    fi
    set_state "lidarrAlbumIsNewRelease" "${albumIsNewRelease}"

    log "INFO :: Starting search for album \"${lidarrAlbumTitle}\" by artist \"${lidarrArtistName}\""

    # Extract artist links
    local deezerArtistIds
    local lidarrArtistInfo="$(get_state "lidarrArtistInfo")"
    local deezerArtistUrl=$(safe_jq '.links[]? | select(.name=="deezer") | .url' <<<"${lidarrArtistInfo}")
    if [ -z "${deezerArtistUrl}" ]; then
        log "WARNING :: Missing Deezer link for artist ${lidarrArtistName}"
    else
        deezerArtistIds=($(echo "${deezerArtistUrl}" | grep -Eo '[[:digit:]]+' | sort -u))
    fi

    # Sort parameter explanations:
    #  - Track count (descending)
    #  - Title length (ascending, as a consistent tiebreaker)

    local lidarrAlbumInfo="$(get_state "lidarrAlbumInfo")"
    jq_filter="[.releases[]
    | .normalized_title = (.title | ascii_downcase)
    | .title_length = (.title | length)
] | sort_by(-.trackCount, .title_length)"
    sorted_releases=$(jq -c "${jq_filter}" <<<"${lidarrAlbumInfo}")

    # Reset search variables
    ResetBestMatch

    # Start search loop
    local exactMatchFound="false"
    mapfile -t releasesArray < <(jq -c '.[]' <<<"$sorted_releases")
    for release_json in "${releasesArray[@]}"; do
        ExtractReleaseInfo "${release_json}"
        local lidarrReleaseTitle="$(get_state "lidarrReleaseTitle")"
        local lidarrReleaseDisambiguation="$(get_state "lidarrReleaseDisambiguation")"

        SetLidarrTitlesToSearch "${lidarrReleaseTitle}" "${lidarrReleaseDisambiguation}"
        local lidarrTitlesToSearch=$(get_state "lidarrTitlesToSearch")
        mapfile -t titleArray <<<"${lidarrTitlesToSearch}"

        local lidarrReleaseForeignId="$(get_state "lidarrReleaseForeignId")"
        log "DEBUG :: Processing Lidarr release \"${lidarrReleaseTitle}\" (${lidarrReleaseForeignId})"

        # Shortcut the evaluation process if the release isn't potentially better in some ways
        if SkipReleaseCandidate; then
            continue
        fi

        # Loop over all titles to search for this release
        for searchReleaseTitle in "${titleArray[@]}"; do
            set_state "searchReleaseTitle" "${searchReleaseTitle}"

            # TODO: Enhance this functionality to intelligently handle releases that are expected to have these keywords
            # Ignore instrumental-like titles if configured
            if [[ "${AUDIO_IGNORE_INSTRUMENTAL_RELEASES}" == "true" ]]; then
                # Convert comma-separated list into an alternation pattern for Bash regex
                IFS=',' read -r -a keywordArray <<<"${AUDIO_INSTRUMENTAL_KEYWORDS}"
                keywordPattern="($(
                    IFS="|"
                    echo "${keywordArray[*]}"
                ))" # join array with | for pattern matching

                if [[ "${searchReleaseTitle}" =~ ${keywordPattern} ]]; then
                    log "DEBUG :: Search title \"${searchReleaseTitle}\" matched instrumental keyword (${AUDIO_INSTRUMENTAL_KEYWORDS}), skipping..."
                    continue
                elif [[ "${searchReleaseTitle,,}" =~ ${keywordPattern,,} ]]; then
                    log "DEBUG :: Search title \"${searchReleaseTitle}\" matched instrumental keyword (${AUDIO_INSTRUMENTAL_KEYWORDS}), skipping..."
                    continue
                fi
            fi

            # Check for commentary keywords in the search title
            local lidarrReleaseContainsCommentary="false"
            IFS=',' read -r -a commentaryArray <<<"${AUDIO_COMMENTARY_KEYWORDS}"
            commentaryPattern="($(
                IFS="|"
                echo "${commentaryArray[*]}"
            ))" # join array with | for pattern matching

            if [[ "${searchReleaseTitle,,}" =~ ${commentaryPattern,,} ]]; then
                log "TRACE :: Search title \"${searchReleaseTitle}\" matched commentary keyword (${AUDIO_COMMENTARY_KEYWORDS})"
                lidarrReleaseContainsCommentary="true"
            elif [[ "${searchReleaseTitle,,}" =~ ${commentaryPattern,,} ]]; then
                log "TRACE :: Search title \"${searchReleaseTitle}\" matched commentary keyword (${AUDIO_COMMENTARY_KEYWORDS})"
                lidarrReleaseContainsCommentary="true"
            fi
            set_state "lidarrReleaseContainsCommentary" "${lidarrReleaseContainsCommentary}"

            # Optionally de-prioritize releases that contain commentary tracks
            bestMatchContainsCommentary=$(get_state "bestMatchContainsCommentary")
            if [[ "${AUDIO_DEPRIORITIZE_COMMENTARY_RELEASES}" == "true" && "${lidarrReleaseContainsCommentary}" == "true" && "${bestMatchContainsCommentary}" == "false" ]]; then
                log "DEBUG :: Already found a match without commentary. Skipping commentary album ${searchReleaseTitle}"
                continue
            fi

            # First search through the artist's Deezer albums to find a match on album title and track count
            log "DEBUG :: Starting search with searchReleaseTitle: ${searchReleaseTitle}"
            if [ "${lidarrArtistForeignArtistId}" != "${VARIOUS_ARTIST_ID_MUSICBRAINZ}" ]; then
                for dId in "${!deezerArtistIds[@]}"; do
                    local deezerArtistId="${deezerArtistIds[$dId]}"
                    ArtistDeezerSearch "${deezerArtistId}"
                done

                # Fuzzy search with album and artist name
                exactMatchFound="$(get_state "exactMatchFound")"
                if [ "${exactMatchFound}" != "true" ]; then
                    FuzzyDeezerSearch "${lidarrArtistName}"
                fi
            fi

            # Fuzzy search with only album name
            exactMatchFound="$(get_state "exactMatchFound")"
            if [ "${exactMatchFound}" != "true" ]; then
                FuzzyDeezerSearch
            fi
        done
    done

    # Write result if configured
    WriteResultFile

    # Download the best match that was found
    local bestMatchID="$(get_state "bestMatchID")"
    if [[ -n "${bestMatchID}" ]]; then
        DownloadBestMatch
    else
        log "INFO :: Album not found"
        local albumIsNewRelease="$(get_state "lidarrAlbumIsNewRelease")"
        if [ ${albumIsNewRelease} == true ]; then
            log "DEBUG :: Skip marking album as not found because it's a new release..."
        else
            log "DEBUG :: Marking album as not found"
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
        log "DEBUG :: Searching albums for Artist ${artistId} (Total Albums: ${resultsCount} found)"

        # Pass filtered albums to the CalculateBestMatch function
        if ((resultsCount > 0)); then
            CalculateBestMatch <<<"${artistAlbums}"
        fi
    else
        log "WARNING :: Failed to fetch album list for Deezer artist ID ${artistId}"
    fi
    log "TRACE :: Exiting ArtistDeezerSearch..."
}

FuzzyDeezerSearch() {
    log "TRACE :: Entering FuzzyDeezerSearch..."
    # $1 -> Deezer Artist Name (default to blank)
    local artistName="${1:-}"

    local deezerSearch=""
    local resultsCount=0
    local url=""

    local searchReleaseTitle
    searchReleaseTitle="$(get_state "searchReleaseTitle")"

    # -------------------------------
    # Normalize and URI-encode album title
    # -------------------------------
    local albumTitleClean albumSearchTerm
    albumTitleClean="$(normalize_string "${searchReleaseTitle}")"
    # Use plain jq here; this is not JSON, just encoding a string
    albumSearchTerm="$(jq -Rn --arg str "$(remove_quotes "${albumTitleClean}")" '$str|@uri')"

    # -------------------------------
    # Build search URL
    # -------------------------------
    if [[ -z "${artistName}" ]]; then
        log "DEBUG :: Fuzzy searching for '${searchReleaseTitle}' with no artist filter..."
        url="https://api.deezer.com/search/album?q=album:${albumSearchTerm}&strict=on&limit=20"
    else
        log "DEBUG :: Fuzzy searching for '${searchReleaseTitle}' with artist name '${artistName}'..."
        local artistNameClean artistSearchTerm
        artistNameClean="$(normalize_string "${artistName}")"
        artistSearchTerm="$(jq -Rn --arg str "$(remove_quotes "${artistNameClean}")" '$str|@uri')"
        url="https://api.deezer.com/search/album?q=artist:${artistSearchTerm}%20album:${albumSearchTerm}&strict=on&limit=20"
    fi

    # -------------------------------
    # Call Deezer API
    # -------------------------------
    CallDeezerAPI "${url}"
    local returnCode=$?
    if ((returnCode != 0)); then
        log "WARNING :: Deezer Fuzzy Search failed for '${searchReleaseTitle}'"
        log "TRACE :: Exiting FuzzyDeezerSearch..."
        return 1
    fi

    deezerSearch="$(get_state "deezerApiResponse" || echo "")"
    log "TRACE :: deezerSearch: ${deezerSearch}"

    # -------------------------------
    # Validate JSON and parse
    # -------------------------------
    if [[ -n "${deezerSearch}" ]] && safe_jq --optional 'true' <<<"${deezerSearch}" >/dev/null 2>&1; then
        resultsCount="$(safe_jq --optional '.total // 0' <<<"${deezerSearch}")"
        log "DEBUG :: ${resultsCount} search results found for '${searchReleaseTitle}'"

        if ((resultsCount > 0)); then
            local formattedAlbums
            formattedAlbums="$(safe_jq '{
                data: ([.data[]] | unique_by(.id | select(. != null))),
                total: ([.data[] | .id] | unique | length)
            }' <<<"${deezerSearch}" || echo '{}')"

            log "TRACE :: Formatted unique album data: ${formattedAlbums}"
            CalculateBestMatch <<<"${formattedAlbums}"
        else
            log "DEBUG :: No results found via Fuzzy Search for '${searchReleaseTitle}'"
        fi
    else
        log "WARNING :: Deezer Fuzzy Search API returned invalid JSON for '${searchReleaseTitle}'"
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
    set_state "searchReleaseTitleClean" "${searchReleaseTitleClean}"

    log "DEBUG :: Calculating best match for \"${searchReleaseTitleClean}\" with ${albumsCount} Deezer albums to compare"

    for ((i = 0; i < albumsCount; i++)); do
        local deezerAlbumData deezerAlbumID deezerAlbumExplicitLyrics

        deezerAlbumData=$(jq -c ".[$i]" <<<"${albums}")
        deezerAlbumID=$(jq -r ".id" <<<"${deezerAlbumData}")
        set_state "deezerCandidateAlbumID" "${deezerAlbumID}"

        # Evaluate this candidate
        EvaluateDeezerAlbumCandidate
    done

    log "TRACE :: Exiting CalculateBestMatch..."
}

# Download the best matching Deezer album found
DownloadBestMatch() {
    log "TRACE :: Entering DownloadBestMatch..."

    local bestMatchID="$(get_state "bestMatchID")"
    local bestMatchTitle="$(get_state "bestMatchTitle")"
    local bestMatchYear="$(get_state "bestMatchYear")"
    local bestMatchDistance="$(get_state "bestMatchDistance")"
    local bestMatchTrackDiff="$(get_state "bestMatchTrackDiff")"
    local bestMatchNumTracks="$(get_state "bestMatchNumTracks")"
    local bestMatchLidarrReleaseForeignId="$(get_state "bestMatchLidarrReleaseForeignId")"

    # Download the best match that was found
    log "INFO :: Downloading best match :: [${bestMatchID}] ${bestMatchTitle} (${bestMatchYear}) :: Distance=${bestMatchDistance} TrackDiff=${bestMatchTrackDiff} NumTracks=${bestMatchNumTracks}"

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

    local deezerAlbumId deezerAlbumTitle deezerAlbumTrackCount downloadedReleaseDate downloadedReleaseYear
    deezerAlbumId=$(jq -r ".id" <<<"${deezerAlbumJson}")
    deezerAlbumTitle=$(jq -r ".title" <<<"${deezerAlbumJson}" | head -n1)
    deezerAlbumTrackCount="$(jq -r .nb_tracks <<<"${deezerAlbumJson}")"
    downloadedReleaseDate=$(jq -r .release_date <<<"${deezerAlbumJson}")
    downloadedReleaseYear="${downloadedReleaseDate:0:4}"

    local returnCode=0
    if [[ -z "$FUNCTIONALTESTDIR" ]]; then

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
            # Delete MusicBrainz files (and empty directories) older than $AUDIO_CACHE_MAX_AGE_DAYS_MUSICBRAINZ days
            if ((AUDIO_CACHE_MAX_AGE_DAYS_MUSICBRAINZ > 0)); then
                find "${AUDIO_WORK_PATH}/cache" -mindepth 1 -type d -name "mb_*" -mtime +"${AUDIO_CACHE_MAX_AGE_DAYS_MUSICBRAINZ}" -exec rm -rf {} +
            fi
            # Delete Deezer files (and empty directories) older than $AUDIO_CACHE_MAX_AGE_DAYS_DEEZER days
            if ((AUDIO_CACHE_MAX_AGE_DAYS_DEEZER > 0)); then
                find "${AUDIO_WORK_PATH}/cache" -mindepth 1 -type d -name "deezer_*" -mtime +"${AUDIO_CACHE_MAX_AGE_DAYS_DEEZER}" -exec rm -rf {} +
            fi
            # Delete Lidarr files (and empty directories) older than $AUDIO_CACHE_MAX_AGE_DAYS_LIDARR days
            if ((AUDIO_CACHE_MAX_AGE_DAYS_LIDARR > 0)); then
                find "${AUDIO_WORK_PATH}/cache" -mindepth 1 -type d -name "lidarr_*" -mtime +"${AUDIO_CACHE_MAX_AGE_DAYS_LIDARR}" -exec rm -rf {} +
            fi
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

        # Check if previously downloaded or failed download
        local lidarrArtistName="$(get_state "lidarrArtistName")"
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

            log "DEBUG :: Download attempt #${downloadTry} for album \"${deezerAlbumTitle}\""
            (
                cd ${DEEMIX_DIR}
                echo "${DEEMIX_ARL}" | deemix \
                    --portable \
                    -p "${AUDIO_WORK_PATH}/staging" \
                    -q FLAC \
                    "https://www.deezer.com/album/${deezerAlbumId}" \
                    2>&1 |
                    while IFS= read -r line; do
                        log "DEBUG :: deemix :: ${line}"
                    done

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
                        log "DEBUG :: File \"${file}\" passed FLAC verification"
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
        log "DEBUG :: Consolidating files to single folder"

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

        # Add the MusicBrainz album info to FLAC and MP3 files
        if [ "$returnCode" -eq 0 ]; then
            local lidarrAlbumTitle=$(get_state "lidarrAlbumTitle")
            local lidarrAlbumForeignAlbumId="$(get_state "lidarrAlbumForeignAlbumId")"
            local lidarrReleaseForeignId="$(get_state "bestMatchLidarrReleaseForeignId")"

            shopt -s nullglob
            for file in "${AUDIO_WORK_PATH}"/staging/*.{flac,mp3}; do
                [ -f "${file}" ] || continue

                case "${file##*.}" in
                flac)
                    metaflac --remove-tag=MUSICBRAINZ_ALBUMID \
                        --remove-tag=MUSICBRAINZ_RELEASEGROUPID \
                        --remove-tag=ALBUM \
                        --set-tag=MUSICBRAINZ_ALBUMID="${lidarrReleaseForeignId}" \
                        --set-tag=MUSICBRAINZ_RELEASEGROUPID="${lidarrAlbumForeignAlbumId}" \
                        --set-tag=ALBUM="${lidarrAlbumTitle}" "${file}"
                    ;;
                mp3)
                    export ALBUM_TITLE=""
                    export MUSICBRAINZ_ALBUMID=""
                    export MUSICBRAINZ_RELEASEGROUPID=""
                    export ALBUMARTIST=""
                    export ARTIST=""
                    export MUSICBRAINZ_ARTISTID=""
                    export ALBUM_TITLE="${lidarrAlbumTitle}"
                    export MUSICBRAINZ_ALBUMID="${lidarrReleaseForeignId}"
                    export MUSICBRAINZ_RELEASEGROUPID="${lidarrAlbumForeignAlbumId}"
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
        else
            log "DEBUG :: Replaygain tagging disabled"
        fi

        # Add Beets tags if enabled
        if [ "${returnCode}" -eq 0 ] && [ "${AUDIO_APPLY_BEETS}" == "true" ]; then
            AddBeetsTags "${AUDIO_WORK_PATH}/staging"
            returnCode=$?
        else
            log "DEBUG :: Beets tagging disabled"
        fi

        # Correct album artist to what is expected by Lidarr
        if [ "$returnCode" -eq 0 ]; then
            local lidarrAlbumInfo="$(get_state "lidarrAlbumInfo")"
            local lidarrArtistForeignArtistId="$(get_state "lidarrArtistForeignArtistId")"

            shopt -s nullglob
            for file in "${AUDIO_WORK_PATH}"/staging/*.{flac,mp3}; do
                [ -f "${file}" ] || continue

                case "${file##*.}" in
                flac)
                    metaflac --remove-tag=MUSICBRAINZ_ARTISTID \
                        --remove-tag=ALBUMARTIST \
                        --remove-tag=ARTIST \
                        --set-tag=MUSICBRAINZ_ARTISTID="${lidarrArtistForeignArtistId}" \
                        --set-tag=ALBUMARTIST="${lidarrArtistName}" \
                        --set-tag=ARTIST="${lidarrArtistName}" "${file}"
                    ;;
                mp3)
                    export ALBUM_TITLE=""
                    export MUSICBRAINZ_ALBUMID=""
                    export MUSICBRAINZ_RELEASEGROUPID=""
                    export ALBUMARTIST=""
                    export ARTIST=""
                    export MUSICBRAINZ_ARTISTID=""
                    export ALBUMARTIST="${lidarrArtistName}"
                    export ARTIST="${lidarrArtistName}"
                    export MUSICBRAINZ_ARTISTID="${lidarrArtistForeignArtistId}"
                    python3 python/MutagenTagger.py "${file}"
                    ;;
                *)
                    log "WARNING :: Skipping unsupported format: ${file}"
                    ;;
                esac
            done
            shopt -u nullglob
        fi
    else
        log "DEBUG :: Skipping audio processing in functional test mode"
    fi

    # Log Completed Download
    if [ "$returnCode" -eq 0 ]; then
        log "DEBUG :: Album \"${deezerAlbumTitle}\" successfully downloaded"
        touch "${AUDIO_DATA_PATH}/downloaded/${lidarrAlbumId}--${lidarrArtistForeignArtistId}--${lidarrAlbumForeignAlbumId}"

        local downloadedAlbumFolder="$(CleanPathString "${lidarrArtistName:0:100}")-$(CleanPathString "${lidarrAlbumTitle:0:100}") (${downloadedReleaseYear})"
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
    log "DEBUG :: Adding ReplayGain Tags using rsgain"

    local returnCode=0
    (
        set +e # temporarily disable -e in subshell
        rsgain easy "${importPath}" 2>&1 |
            while IFS= read -r line; do
                log "DEBUG :: rsgain :: ${line}"
            done

        exit ${PIPESTATUS[0]}
    )
    returnCode=$? # capture exit code of subshell

    log "TRACE :: Exiting AddReplaygainTags..."
    return $returnCode
}

# Add Beets tags to audio files in the specified folder
AddBeetsTags() {
    log "TRACE :: Entering AddBeetsTags..."
    # $1 -> folder path containing audio files to be tagged
    local importPath="${1}"
    log "DEBUG :: Adding Beets tags"

    # Setup
    rm -f "${BEETS_DIR}/beets-library.blb"
    rm -f "${BEETS_DIR}/beets.log"
    rm -f "${BEETS_DIR}/beets.timer"
    touch "${BEETS_DIR}/beets-library.blb"
    touch "${BEETS_DIR}/beets.timer"

    local lidarrReleaseForeignId="$(get_state "bestMatchLidarrReleaseForeignId")"

    # Retry settings
    local max_retries=3
    local delay=5
    local attempt=0

    while :; do
        local returnCode=0
        # Process with Beets
        (
            set +e # disable -e temporarily in subshell
            export XDG_CONFIG_HOME="${BEETS_DIR}/.config"
            export HOME="${BEETS_DIR}"
            mkdir -p "${XDG_CONFIG_HOME}"

            # Determine if output should be suppressed
            local beetOutputTarget beetVerbosityFlag
            if DebugLogging; then
                beetOutputTarget="/dev/stderr" # show all output
                beetVerbosityFlag="-v"
                if TraceLogging; then
                    beetVerbosityFlag="-vv"
                fi
            else
                beetOutputTarget="/dev/null" # suppress output
                beetVerbosityFlag=""
            fi

            : >"${BEETS_DIR}/beets.log"
            beet -c "${BEETS_DIR}/beets.yaml" \
                -l "${BEETS_DIR}/beets-library.blb" \
                -d "${importPath}" ${beetVerbosityFlag} import -qCw \
                -S "${lidarrReleaseForeignId}" \
                "${importPath}" >"$beetOutputTarget" 2>&1

            returnCode=$? # <- captures exit code of subshell
            if [ $returnCode -ne 0 ]; then
                log "WARNING :: Beets returned error code ${returnCode}"
            else
                log "DEBUG :: Successfully added Beets tags"
            fi

            exit $returnCode
        ) || returnCode=$?
        log "DEBUG :: Beets subshell returned ${returnCode}"

        # Success?
        if [ $returnCode -eq 0 ]; then
            if grep -Eq "MusicBrainz not reachable|NetworkError|UNEXPECTED_EOF_WHILE_READING" \
                "${BEETS_DIR}/beets.log" 2>/dev/null; then
                returnCode=75 # semantic retry signal
                log "WARNING :: MusicBrainz network failure detected in beets.log"
            else
                break
            fi
        fi

        # Retry?
        if [ $attempt -lt $max_retries ]; then
            attempt=$((attempt + 1))
            log "WARNING :: Beets failed (rc=${returnCode}) — retrying in ${delay}s (attempt ${attempt}/${max_retries})..."
            sleep $delay
            delay=$((delay * 2))
            continue
        fi

        # Retries exhausted
        break
    done

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

log "DEBUG :: FUNCTIONALTESTDIR=${FUNCTIONALTESTDIR:-}"
log "DEBUG :: AUDIO_APPLY_BEETS=${AUDIO_APPLY_BEETS}"
log "DEBUG :: AUDIO_APPLY_REPLAYGAIN=${AUDIO_APPLY_REPLAYGAIN}"
log "DEBUG :: AUDIO_CACHE_MAX_AGE_DAYS_DEEZER=${AUDIO_CACHE_MAX_AGE_DAYS_DEEZER}"
log "DEBUG :: AUDIO_CACHE_MAX_AGE_DAYS_LIDARR=${AUDIO_CACHE_MAX_AGE_DAYS_LIDARR}"
log "DEBUG :: AUDIO_CACHE_MAX_AGE_DAYS_MUSICBRAINZ=${AUDIO_CACHE_MAX_AGE_DAYS_MUSICBRAINZ}"
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
log "DEBUG :: AUDIO_MATCH_THRESHOLD_TITLE=${AUDIO_MATCH_THRESHOLD_TITLE}"
log "DEBUG :: AUDIO_MATCH_THRESHOLD_TRACKS=${AUDIO_MATCH_THRESHOLD_TRACKS}"
log "DEBUG :: AUDIO_MATCH_THRESHOLD_TRACK_DIFF_AVG=${AUDIO_MATCH_THRESHOLD_TRACK_DIFF_AVG}"
log "DEBUG :: AUDIO_MATCH_THRESHOLD_TRACK_DIFF_MAX=${AUDIO_MATCH_THRESHOLD_TRACK_DIFF_MAX}"
log "DEBUG :: AUDIO_PREFERRED_COUNTRIES=${AUDIO_PREFERRED_COUNTRIES}"
log "DEBUG :: AUDIO_PREFERRED_FORMATS=${AUDIO_PREFERRED_FORMATS}"
log "DEBUG :: AUDIO_REQUIRE_QUALITY=${AUDIO_REQUIRE_QUALITY}"
log "DEBUG :: AUDIO_RESULT_FILE_NAME=${AUDIO_RESULT_FILE_NAME}"
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
AddDownloadClient

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
    # Clear cache data from previous runs
    ClearTrackComparisonCache

    ProcessLidarrWantedList "missing"
    ProcessLidarrWantedList "cutoff"

    log "INFO :: Script sleeping for ${AUDIO_INTERVAL}..."
    sleep ${AUDIO_INTERVAL}
done

exit 0
