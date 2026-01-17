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
readonly VARIOUS_ARTIST_ID_DEEZER="5080"
readonly DEEMIX_DIR="/tmp/deemix"
readonly DEEMIX_CONFIG_PATH="${DEEMIX_DIR}/config/config.json"
readonly BEETS_DIR="/tmp/beets"
readonly BEETS_CONFIG_PATH="${BEETS_DIR}/beets.yaml"

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
    LoadTitleReplacements

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

    # Perform matching process
    FindDeezerMatch

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
            local lidarrArtistForeignArtistId="$(get_state "lidarrArtistForeignArtistId")"
            local lidarrAlbumForeignAlbumId="$(get_state "lidarrAlbumForeignAlbumId")"
            if [ ! -f "${AUDIO_DATA_PATH}/notfound/${lidarrAlbumId}--${lidarrArtistForeignArtistId}--${lidarrAlbumForeignAlbumId}" ]; then
                touch "${AUDIO_DATA_PATH}/notfound/${lidarrAlbumId}--${lidarrArtistForeignArtistId}--${lidarrAlbumForeignAlbumId}"
            fi
        fi
    fi

    log "TRACE :: Exiting SearchProcess..."
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
    if [[ -z "${FUNCTIONALTESTDIR:-}" ]]; then

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
        local deemixQuality="flac"
        while true; do
            downloadTry=$(($downloadTry + 1))

            # Stop trying after too many attempts
            if ((downloadTry >= AUDIO_DOWNLOAD_ATTEMPT_THRESHOLD)); then
                if [ "${AUDIO_DOWNLOAD_QUALITY_FALLBACK}" == "true" ] && [ "${deemixQuality}" == "flac" ]; then
                    log "WARNING :: Album \"${deezerAlbumTitle}\" failed to download after ${downloadTry} attempts...Attempting quality fallback..."
                    rm -rf "${AUDIO_WORK_PATH}/staging"/*
                    deemixQuality="mp3"
                else
                    log "WARNING :: Album \"${deezerAlbumTitle}\" failed to download after ${downloadTry} attempts...Skipping..."
                    touch "${AUDIO_DATA_PATH}/failed/${deezerAlbumId}"
                    return
                fi
            fi

            log "DEBUG :: Download attempt #${downloadTry} for album \"${deezerAlbumTitle}\""
            (
                cd ${DEEMIX_DIR}
                echo "${DEEMIX_ARL}" | deemix \
                    --portable \
                    -p "${AUDIO_WORK_PATH}/staging" \
                    -b "${deemixQuality}" \
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
                    log "TRACE :: Tagging file ${file} with MusicBrainz album info: MUSICBRAINZ_ALBUMID=${lidarrReleaseForeignId}, MUSICBRAINZ_RELEASEGROUPID=${lidarrAlbumForeignAlbumId}, ALBUM=${lidarrAlbumTitle}"
                    metaflac --remove-tag=MUSICBRAINZ_ALBUMID \
                        --remove-tag=MUSICBRAINZ_RELEASEGROUPID \
                        --remove-tag=ALBUM \
                        --set-tag=MUSICBRAINZ_ALBUMID="${lidarrReleaseForeignId}" \
                        --set-tag=MUSICBRAINZ_RELEASEGROUPID="${lidarrAlbumForeignAlbumId}" \
                        --set-tag=ALBUM="${lidarrAlbumTitle}" "${file}"
                    ;;
                mp3)
                    log "TRACE :: Tagging file ${file} with MusicBrainz album info: MUSICBRAINZ_ALBUMID=${lidarrReleaseForeignId}, MUSICBRAINZ_RELEASEGROUPID=${lidarrAlbumForeignAlbumId}, ALBUM_TITLE=${lidarrAlbumTitle}"
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
log "DEBUG :: AUDIO_DOWNLOAD_QUALITY_FALLBACK=${AUDIO_DOWNLOAD_QUALITY_FALLBACK}"
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
log "DEBUG :: AUDIO_REQUIRE_MUSICBRAINZ_REL=${AUDIO_REQUIRE_MUSICBRAINZ_REL}"
log "DEBUG :: AUDIO_REQUIRE_QUALITY=${AUDIO_REQUIRE_QUALITY}"
log "DEBUG :: AUDIO_RESULT_FILE_NAME=${AUDIO_RESULT_FILE_NAME}"
log "DEBUG :: AUDIO_RETRY_DOWNLOADED_DAYS=${AUDIO_RETRY_DOWNLOADED_DAYS}"
log "DEBUG :: AUDIO_RETRY_FAILED_DAYS=${AUDIO_RETRY_FAILED_DAYS}"
log "DEBUG :: AUDIO_RETRY_NOTFOUND_DAYS=${AUDIO_RETRY_NOTFOUND_DAYS}"
log "DEBUG :: AUDIO_SHARED_LIDARR_PATH=${AUDIO_SHARED_LIDARR_PATH}"
log "DEBUG :: AUDIO_TIEBREAKER_COUNTRIES=${AUDIO_TIEBREAKER_COUNTRIES}"
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

    if [ ! -d "${AUDIO_DATA_PATH}/notfound" ]; then
        mkdir -p "${AUDIO_DATA_PATH}"/notfound
    fi

    ProcessLidarrWantedList "missing"
    ProcessLidarrWantedList "cutoff"

    # If AUDIO_INTERVAL is "none", run only once
    if [[ "${AUDIO_INTERVAL}" == "none" ]]; then
        log "INFO :: AUDIO_INTERVAL is 'none', exiting after single run..."
        break
    fi
    log "INFO :: Script sleeping for ${AUDIO_INTERVAL}..."
    sleep ${AUDIO_INTERVAL}
done

exit 0
