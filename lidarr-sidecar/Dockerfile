# ===== Final Stage =====
FROM debian:13.1-slim

# Install runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    beets \
    flac \
    jq \
    ffmpeg \
    python3 \
    python3-pip \
    curl \
    bash \
    rsgain
RUN rm -rf /var/lib/apt/lists/*

# Install Python packages into a custom prefix
RUN pip install --no-cache-dir --prefer-binary --break-system-packages \
    yq \
    beautifulsoup4 \
    jellyfish \
    pyacoustid \
    pylast \
    requests \
    mutagen \
    deemix \
    langdetect

# Copy scripts and config
COPY lidarr-sidecar/ /app/
COPY shared/ /app/
RUN chmod +x /app/entrypoint.sh

WORKDIR /app

# General settings
ENV LOG_LEVEL=INFO

# Application details
ENV ARR_NAME=Lidarr
ENV ARR_CONFIG_PATH=/lidarr/config.xml
ENV ARR_SUPPORTED_API_VERSIONS=v1
ENV ARR_HOST=lidarr
ENV ARR_PORT=

# ARLChecker settings
ENV ARLUPDATE_INTERVAL=24h

# Audio settings
ENV AUDIO_APPLY_BEETS=true
ENV AUDIO_APPLY_REPLAYGAIN=true
ENV AUDIO_CACHE_MAX_AGE_DAYS=30
ENV AUDIO_BEETS_CUSTOM_CONFIG=
ENV AUDIO_COMMENTARY_KEYWORDS="commentary,commentaries,directors commentary,audio commentary,with commentary,track by track"
ENV AUDIO_DATA_PATH=/data
ENV AUDIO_DEEMIX_CUSTOM_CONFIG=
ENV AUDIO_DEEZER_API_RETRIES=3
ENV AUDIO_DEEZER_API_TIMEOUT=30
ENV AUDIO_DEEMIX_ARL_FILE=/deemix_arl_token
ENV AUDIO_DEPRIORITIZE_COMMENTARY_RELEASES=true
ENV AUDIO_DOWNLOADCLIENT_NAME=lidarr-deemix-sidecar
ENV AUDIO_DOWNLOAD_ATTEMPT_THRESHOLD=10
ENV AUDIO_DOWNLOAD_CLIENT_TIMEOUT=10m
ENV AUDIO_FAILED_ATTEMPT_THRESHOLD=6
ENV AUDIO_IGNORE_INSTRUMENTAL_RELEASES=true
ENV AUDIO_INSTRUMENTAL_KEYWORDS="Instrumental,Score"
ENV AUDIO_INTERVAL=15m
ENV AUDIO_LYRIC_TYPE=prefer-explicit
ENV AUDIO_MATCH_DISTANCE_THRESHOLD=0
ENV AUDIO_PREFERED_COUNTRIES="[Worldwide],United States"
ENV AUDIO_PREFERED_FORMATS="Digital Media,CD"
ENV AUDIO_REQUIRE_QUALITY=true
ENV AUDIO_RETRY_NOTFOUND_DAYS=90
ENV AUDIO_RETRY_DOWNLOADED_DAYS=180
ENV AUDIO_RETRY_FAILED_DAYS=90
ENV AUDIO_SHARED_LIDARR_PATH=/sidecar-import
ENV AUDIO_TITLE_REPLACEMENTS_FILE=/app/config/album_title_replacements.json
ENV AUDIO_WORK_PATH=/work

# AutoConfig settings
ENV AUTOCONFIG_DELAY=10
ENV AUTOCONFIG_CUSTOMFORMAT=false
ENV AUTOCONFIG_CUSTOMFORMAT_JSON=/app/config/customformat.json
ENV AUTOCONFIG_DOWNLOADCLIENT=false
ENV AUTOCONFIG_DOWNLOADCLIENT_JSON=/app/config/downloadclient.json
ENV AUTOCONFIG_HOST=true
ENV AUTOCONFIG_HOST_JSON=/app/config/host.json
ENV AUTOCONFIG_MEDIAMANAGEMENT=true
ENV AUTOCONFIG_MEDIAMANAGEMENT_JSON=/app/config/mediamanagement.json
ENV AUTOCONFIG_METADATA=true
ENV AUTOCONFIG_METADATA_JSON=/app/config/metadata.json
ENV AUTOCONFIG_METADATAPROFILE=false
ENV AUTOCONFIG_METADATAPROFILE_JSON=/app/config/metadataprofile.json
ENV AUTOCONFIG_METADATAPROVIDER=true
ENV AUTOCONFIG_METADATAPROVIDER_JSON=/app/config/metadataprovider.json
ENV AUTOCONFIG_NAMING=true
ENV AUTOCONFIG_NAMING_JSON=/app/config/naming.json
ENV AUTOCONFIG_QUALITYPROFILE=true
ENV AUTOCONFIG_QUALITYPROFILE_JSON=/app/config/qualityprofile.json
ENV AUTOCONFIG_UI=false
ENV AUTOCONFIG_UI_JSON=/app/config/ui.json

CMD ["bash", "/app/entrypoint.sh"]
