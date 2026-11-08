# ===== Final Stage =====
FROM debian:13.7-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2 AS runtime

LABEL org.opencontainers.image.description="Lidarr music video sidecar - official music videos of Lidarr artists from YouTube"
LABEL org.opencontainers.image.licenses="GPL-3.0-only"

# ffmpeg merges the video and audio streams and converts thumbnails. Debian rather than Alpine:
# the deno wheels yt-dlp uses for YouTube's JavaScript challenges are built for glibc.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    python3 \
    python3-pip \
    tini \
    tzdata \
    && rm -rf /var/lib/apt/lists/*

COPY lidarr-musicvideo-sidecar/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir --prefer-binary --break-system-packages -r /tmp/requirements.txt

COPY lidarr-musicvideo-sidecar/ /app/
COPY shared/python /app/shared/python/

WORKDIR /app
ENV PYTHONPATH=/app

# General settings
ENV UMASK=0002
ENV LOG_LEVEL=INFO

# Application details
ENV ARR_NAME=Lidarr
ENV ARR_CONFIG_PATH=/lidarr/config.xml
ENV ARR_SUPPORTED_API_VERSIONS=v1
ENV ARR_HOST=lidarr
ENV ARR_PORT=

# MusicVideoDownloader settings
ENV VIDEO_LIBRARY_PATH=/music-videos
ENV VIDEO_STATE_DIR=/data
ENV VIDEO_WORK_DIR=/work
ENV VIDEO_INTERVAL=24h
ENV VIDEO_ARTIST_TAG=
ENV VIDEO_MAX_DOWNLOADS_PER_RUN=10
ENV VIDEO_ARTIST_RECHECK_DAYS=7
ENV VIDEO_DOWNLOAD_ATTEMPT_THRESHOLD=3
ENV VIDEO_DOWNLOAD_DELAY=30
ENV VIDEO_MIN_DURATION=90
ENV VIDEO_MAX_DURATION=900
ENV VIDEO_FORMAT="bv*+ba/b"
ENV VIDEO_COOKIES_FILE=
ENV VIDEO_DRY_RUN=false
# yt-dlp and deno need a writable cache; the root filesystem is read-only in hardened deployments
ENV DENO_DIR=/tmp/deno
ENV XDG_CACHE_HOME=/tmp/.cache

# Runs as an unprivileged user by default; deployments can override it with `user:`
RUN groupadd --system --gid 1000 sidecar && useradd --system --uid 1000 --gid 1000 --no-create-home sidecar
USER 1000:1000

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD test "$(cat /tmp/health 2>/dev/null)" = "healthy"

# tini as PID 1 for signal forwarding + zombie reaping
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["python3", "/app/shared/python/entrypoint.py"]

# Test stage: CI builds this target on every platform before publishing
FROM runtime AS test
COPY --chown=1000:1000 . /src
WORKDIR /src
RUN PYTHONPATH=/src python3 -m unittest discover -s shared/python/tests -p 'test_*.py' \
    && PYTHONPATH=/src python3 -m unittest discover -s lidarr-musicvideo-sidecar/python/tests -p 'test_*.py'

FROM runtime
