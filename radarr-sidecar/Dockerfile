# Use latest Alpine as base
FROM alpine:latest

# Install system dependencies
RUN apk add --no-cache \
    bash \
    curl \
    jq \
    python3-dev \
    uv

# Install Python packages
RUN uv pip install --system --upgrade --no-cache-dir --break-system-packages \
    yq

# Copy all scripts and config files
COPY radarr-sidecar/ /app/
COPY shared/ /app/
RUN chmod +x /app/entrypoint.sh

# Set working directory
WORKDIR /app

### Variable defaults ###

# General settings
ENV LOG_LEVEL=INFO

# Application details
ENV ARR_NAME=radarr
ENV ARR_CONFIG_PATH=/radarr/config.xml
ENV ARR_SUPPORTED_API_VERSIONS=v3,v1
ENV ARR_HOST=radarr
ENV ARR_PORT=

# AutoConfig settings
ENV AUTOCONFIG_MEDIAMANAGEMENT=true
ENV AUTOCONFIG_MEDIAMANAGEMENT_JSON=/app/config/mediamanagement.json
ENV AUTOCONFIG_HOST=true
ENV AUTOCONFIG_HOST_JSON=/app/config/host.json
ENV AUTOCONFIG_CUSTOMFORMAT=true
ENV AUTOCONFIG_CUSTOMFORMAT_JSON=/app/config/customformat.json
ENV AUTOCONFIG_UI=true
ENV AUTOCONFIG_UI_JSON=/app/config/ui.json
ENV AUTOCONFIG_QUALITYPROFILE=true
ENV AUTOCONFIG_QUALITYPROFILE_JSON=/app/config/qualityprofile.json
ENV AUTOCONFIG_NAMING=true
ENV AUTOCONFIG_NAMING_JSON=/app/config/naming.json

# AutoImport settings
ENV AUTOIMPORT_CACHE_HOURS=1
ENV AUTOIMPORT_DROP_DIR=/drop
ENV AUTOIMPORT_DOWNLOADCLIENT_NAME=radarr-sidecar
#ENV AUTOIMPORT_GROUP= #Needs to be unset
ENV AUTOIMPORT_IMPORT_MARKER=import-
ENV AUTOIMPORT_INTERVAL=5m
ENV AUTOIMPORT_SHARED_PATH=/sidecar-import
ENV AUTOIMPORT_TAGS=autoimport
ENV AUTOIMPORT_WORK_DIR=/work

# Entrypoint
CMD ["bash", "/app/entrypoint.sh"]
