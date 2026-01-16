#!/usr/bin/env bash
set -uo pipefail

# --- Setup environment ---

# Required packages
sudo apk add --no-cache python3 py3-pip
sudo pip install --no-cache-dir --prefer-binary --break-system-packages yq

# Copy scripts to /tmp/lidarr-sidecar-deemixdownloader-test to simulate actual runtime environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rm -r "/tmp/lidarr-sidecar-deemixdownloader-test"
mkdir -p /tmp/lidarr-sidecar-deemixdownloader-test
cp -r "$SCRIPT_DIR/../services" /tmp/lidarr-sidecar-deemixdownloader-test/services
cp -r "$SCRIPT_DIR/../../shared"/*.sh /tmp/lidarr-sidecar-deemixdownloader-test/

mkdir -p "$SCRIPT_DIR/data"
mkdir -p "$SCRIPT_DIR/work"
rm "$SCRIPT_DIR/work/results.md"

# Set necessary environment variables for DeemixDownloader
export LOG_LEVEL="DEBUG"
export ARR_NAME=Lidarr
export ARR_CONFIG_PATH="$SCRIPT_DIR/config/lidarr/config.xml"
export ARR_SUPPORTED_API_VERSIONS=v1
export ARR_HOST=lidarr
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
export AUDIO_TIEBREAKER_COUNTRIES="United States,[Worldwide],Canada,Europe,United Kingdom,Australia,[BLANK]"
export AUDIO_TITLE_REPLACEMENTS_FILE="$SCRIPT_DIR/config/album_title_replacements.json"
export AUDIO_WORK_PATH="$SCRIPT_DIR/work"

# Indicate functional testing mode
export FUNCTIONALTESTDIR="$SCRIPT_DIR"

echo "----------------------------------------------"
source "/tmp/lidarr-sidecar-deemixdownloader-test/services/DeemixDownloader.bash"
echo "----------------------------------------------"

exit 0
