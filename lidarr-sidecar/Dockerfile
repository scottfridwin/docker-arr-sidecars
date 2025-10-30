# Use latest Alpine as base
FROM alpine:latest

# Install system dependencies
RUN apk add --no-cache \
    beets \
    tidyhtml \
    musl-locales \
    musl-locales-lang \
    flac \
    jq \
    ffmpeg \
    imagemagick \
    opus-tools \
    opustags \
    python3-dev \
    libc-dev \
    uv \
    parallel \
    chromaprint \
    curl \
    id3v2 \
    bash

# Install atomicparsley from edge/testing
RUN apk add --no-cache -X http://dl-cdn.alpinelinux.org/alpine/edge/testing atomicparsley

# Install Python packages
RUN uv pip install --system --upgrade --no-cache-dir --break-system-packages \
    jellyfish \
    beautifulsoup4 \
    yt-dlp \
    yq \
    pyacoustid \
    requests \
    colorama \
    pylast \
    mutagen \
    r128gain \
    deemix \
    langdetect \
    apprise

# Copy all scripts and config files
COPY lidarr-sidecar/ /app/
COPY shared/ /app/
RUN chmod +x /app/entrypoint.sh

# Set working directory
WORKDIR /app

### Variable defaults ###

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
ENV AUDIO_MATCH_DISTANCE_THRESHOLD=3
ENV AUDIO_PREFER_SPECIAL_EDITIONS=true
ENV AUDIO_REQUIRE_QUALITY=true
ENV AUDIO_RETRY_NOTFOUND_DAYS=90
ENV AUDIO_SHARED_LIDARR_PATH=/sidecar-import
ENV AUDIO_TAGS=deemix
ENV AUDIO_TITLE_REPLACEMENTS_FILE=/app/config/album_title_replacements.json
ENV AUDIO_WORK_PATH=/work

# AutoConfig settings
ENV AUTOCONFIG_MEDIA_MANAGEMENT=true
ENV AUTOCONFIG_MEDIA_MANAGEMENT_JSON=/app/config/media_management.json
ENV AUTOCONFIG_METADATA_CONSUMER=false
ENV AUTOCONFIG_METADATA_CONSUMER_JSON=/app/config/metadata_consumer.json
ENV AUTOCONFIG_METADATA_PROVIDER=true
ENV AUTOCONFIG_METADATA_PROVIDER_JSON=/app/config/metadata_provider.json
ENV AUTOCONFIG_LIDARR_UI=false
ENV AUTOCONFIG_LIDARR_UI_JSON=/app/config/lidarr_ui.json
ENV AUTOCONFIG_METADATA_PROFILE=true
ENV AUTOCONFIG_METADATA_PROFILE_JSON=/app/config/metadata_profile.json
ENV AUTOCONFIG_TRACK_NAMING=true
ENV AUTOCONFIG_TRACK_NAMING_JSON=/app/config/track_naming.json

# Entrypoint
CMD ["bash", "/app/entrypoint.sh"]
