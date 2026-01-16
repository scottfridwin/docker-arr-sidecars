#!/usr/bin/env bash
set -uo pipefail

# --- Source the function under test ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../shared/utilities.sh"
source "${SCRIPT_DIR}/../services/functions.bash"

#### Mocks ####
log() {
    #: # Do nothing, suppress logs in tests
    local msg="$1"
    echo "${scriptName} :: ${msg}" >>"$SCRIPT_DIR/work/${scriptName}.log"
}

# --- Parse arguments ---
if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <Lidarr Address> <Lidarr API Port> <Lidarr API Key>"
    exit 1
fi

lidarrAddress="${1}"
lidarrApiPort="${2}"
lidarrApiKey="${3}"

# --- Setup environment ---

scriptName="FT-SearchProcess"

# Required packages
sudo apk add --no-cache python3 py3-pip 2>&1 >/dev/null
sudo pip install --no-cache-dir --prefer-binary --break-system-packages yq 2>&1 >/dev/null

# Write temporary config file
mkdir -p /tmp/lidarr-sidecar-${scriptName}/config/lidarr
configFile="/tmp/lidarr-sidecar-${scriptName}/config/lidarr/config.xml"
echo "<Config>" >"$configFile"
echo "  <Port>${lidarrApiPort}</Port>" >>"$configFile"
echo "  <ApiKey>${lidarrApiKey}</ApiKey>" >>"$configFile"
echo "  <InstanceName>Lidarr</InstanceName>" >>"$configFile"
echo "</Config>" >>"$configFile"

mkdir -p "$SCRIPT_DIR/data"
mkdir -p "$SCRIPT_DIR/work"
echo "" >"$SCRIPT_DIR/work/${scriptName}.log"

# Set necessary environment variables for DeemixDownloader
export LOG_LEVEL="TRACE"
export ARR_NAME=Lidarr
export ARR_CONFIG_PATH="$configFile"
export ARR_SUPPORTED_API_VERSIONS=v1
export ARR_HOST="${lidarrAddress}"
export ARR_PORT=
export AUDIO_APPLY_BEETS=true
export AUDIO_APPLY_REPLAYGAIN=true
export AUDIO_CACHE_MAX_AGE_DAYS_DEEZER=-1
export AUDIO_CACHE_MAX_AGE_DAYS_LIDARR=-1
export AUDIO_CACHE_MAX_AGE_DAYS_MUSICBRAINZ=-1
export AUDIO_BEETS_CUSTOM_CONFIG=
export AUDIO_COMMENTARY_KEYWORDS="commentary,commentaries,directors commentary,audio commentary,with commentary,track by track"
export AUDIO_DATA_PATH="$SCRIPT_DIR/data"
export AUDIO_DEEMIX_CUSTOM_CONFIG=
export AUDIO_DEEZER_API_RETRIES=3
export AUDIO_DEEZER_API_TIMEOUT=30
export AUDIO_DEEMIX_ARL_FILE="$SCRIPT_DIR/config/deemix_arl"
export AUDIO_DEPRIORITIZE_COMMENTARY_RELEASES=true
export AUDIO_DOWNLOADCLIENT_NAME=lidarr-deemix-sidecar
export AUDIO_DOWNLOAD_ATTEMPT_THRESHOLD=10
export AUDIO_DOWNLOAD_CLIENT_TIMEOUT=10m
export AUDIO_DOWNLOAD_QUALITY_FALLBACK=true
export AUDIO_FAILED_ATTEMPT_THRESHOLD=6
export AUDIO_IGNORE_INSTRUMENTAL_RELEASES=true
export AUDIO_INSTRUMENTAL_KEYWORDS="Instrumental,Score"
export AUDIO_INTERVAL="none"
export AUDIO_LYRIC_TYPE=prefer-explicit
export AUDIO_MATCH_THRESHOLD_TITLE=0
export AUDIO_MATCH_THRESHOLD_TRACKS=0
export AUDIO_MATCH_THRESHOLD_TRACK_DIFF_AVG=1.00
export AUDIO_MATCH_THRESHOLD_TRACK_DIFF_MAX=10
export AUDIO_PREFERRED_COUNTRIES="[Worldwide]|United States|United Kingdom|Australia|Europe|Canada|[BLANK]"
export AUDIO_PREFERRED_FORMATS="Digital Media|CD"
export AUDIO_REQUIRE_MUSICBRAINZ_REL=true
export AUDIO_REQUIRE_QUALITY=true
export AUDIO_RESULT_FILE_NAME=results.md
export AUDIO_RETRY_NOTFOUND_DAYS=90
export AUDIO_RETRY_DOWNLOADED_DAYS=180
export AUDIO_RETRY_FAILED_DAYS=90
export AUDIO_SHARED_LIDARR_PATH="$SCRIPT_DIR/work"
export AUDIO_TIEBREAKER_COUNTRIES="[Worldwide],United States,Canada,Europe,United Kingdom,Australia,[BLANK]"
export AUDIO_TITLE_REPLACEMENTS_FILE="$SCRIPT_DIR/config/album_title_replacements.json"
export AUDIO_WORK_PATH="$SCRIPT_DIR/work"

# --- Define test cases ---
#TESTS=({1..250})
TESTS=(112)

# --- Run tests ---
pass=0
fail=0
unknown=0

echo "----------------------------------------------"

init_state
for albumId in "${TESTS[@]}"; do
    # Start timer
    start_time=$(date +%s.%N)

    reset_state
    LoadTitleReplacements
    set_state "lidarrAlbumId" "$albumId"
    FindDeezerMatch

    # Look up the album id to see if we have an expected match
    lidarrAlbumForeignAlbumId=$(get_state "lidarrAlbumForeignAlbumId")
    expectedMatchFile="$SCRIPT_DIR/KnownMatches.json"
    matchRecord="$(
        safe_jq --optional --arg rgid "$lidarrAlbumForeignAlbumId" \
            'first(.[] | select(.releaseGroupId == $rgid))' \
            <"$expectedMatchFile"
    )"
    resultString=""
    if [[ "$matchRecord" == "null" || -z "$matchRecord" ]]; then
        resultString=$(printf "⚠️  UNKNOWN: %-4s → %s\n" "$albumId" "No known match record")
        unknown=$((unknown + 1))
    else
        # Get expected IDs from the known match record
        expectedDeezerId="$(safe_jq --optional '.deezerId' <<<"$matchRecord")"
        expectedReleaseId="$(safe_jq --optional '.releaseId' <<<"$matchRecord")"

        # Get the search results and compare to known match
        bestMatchID="$(get_state "bestMatchID")"
        bestMatchLidarrReleaseForeignId="$(get_state "bestMatchLidarrReleaseForeignId")"
        if [[ -n "${bestMatchID}" ]]; then
            if [[ "${bestMatchID}" == "${expectedDeezerId}" ]] && [[ "${bestMatchLidarrReleaseForeignId}" == "${expectedReleaseId}" ]]; then
                resultString=$(printf "✅ PASS: %-4s → %s\n" "$albumId" "Successful match")
                pass=$((pass + 1))
            else
                resultString=$(printf "❌ FAIL: %-4s → %s\n" "$albumId" "Incorrect match; Expected Deezer ID: ${expectedDeezerId}, Got: ${bestMatchID}; Expected Release ID: ${expectedReleaseId}, Got: ${bestMatchLidarrReleaseForeignId}")
                fail=$((fail + 1))
            fi
        else
            # No best match found
            # If the known match record indicates a blank deezerId, then this is expected
            if [[ -z "${expectedDeezerId}" || "${expectedDeezerId}" == "null" ]]; then
                resultString=$(printf "✅ PASS: %-4s → %s\n" "$albumId" "Successful no-match")
                pass=$((pass + 1))
            else
                resultString=$(printf "❌ FAIL: %-4s → %s\n" "$albumId" "Expected a match but one was not found; Expected Deezer ID: ${expectedDeezerId}, Expected Release ID: ${expectedReleaseId}")
                fail=$((fail + 1))
            fi
        fi
    fi

    # Calculate elapsed time
    end_time=$(date +%s.%N)
    elapsed=$(echo "$end_time - $start_time" | bc)
    resultString+=" (Time: $(printf "%.2f" "$elapsed")s)"

    echo "$resultString"
done

echo "----------------------------------------------"
echo "Passed: $pass, Failed: $fail, Unknown: $unknown"

exit 0
