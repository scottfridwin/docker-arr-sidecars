# Lidarr Sidecar

Automates Lidarr wanted-album acquisition from Deezer using MusicBrainz-linked releases.

## Container Image

- Package: <https://github.com/scottfridwin/docker-arr-sidecars/pkgs/container/lidarr-sidecar>
- Pull: `docker pull ghcr.io/scottfridwin/lidarr-sidecar:latest`

## Services

- AutoConfig (`services/one-time/AutoConfig.py`)
  - Applies JSON-based Lidarr defaults from `config/`
- ARLChecker (`services/persistent/ARLChecker.py`)
  - Validates Deezer ARL token file ownership/permissions on a schedule
- DeemixDownloader (`services/persistent/DeemixDownloader.py`)
  - Polls wanted albums
  - Resolves Deezer album IDs through MusicBrainz release relations
  - Validates candidate links (title, track count, lyric filters)
  - Deprioritizes redirected Deezer IDs when direct IDs are available
  - Downloads via deemix, applies optional ReplayGain/Beets, and triggers Lidarr import
  - Writes `DEEZER_ALBUM_ID` metadata to downloaded FLAC/MP3 files

## Required Mounts

- Lidarr config XML:
  - `/path/to/lidarr/config.xml:/lidarr/config.xml:ro`
- Working path (state/cache/temp):
  - `/path/to/work:/work`
- Shared import path (also mounted in Lidarr):
  - `/path/to/shared/import:/sidecar-import`
- Deezer ARL token file:
  - `/secure/path/deemix_arl_token:/deemix_arl_token:rw`

## Important Environment Variables

General:

- `ARR_CONFIG_PATH` (default: `/lidarr/config.xml`)
- `ARR_HOST` (default: `lidarr`)
- `ARR_SUPPORTED_API_VERSIONS` (default: `v1`)
- `LOG_LEVEL` (default: `INFO`)
- `UMASK` (default: `0002`)

Downloader behavior:

- `AUDIO_INTERVAL` (default: `15m`)
- `AUDIO_PRIORITY_FILE` (optional)
- `AUDIO_PRIORITY_ONLY` (default: `false`)
- `AUDIO_DAILY_DOWNLOAD_LIMIT` (default: `0`, unlimited)
- `AUDIO_LYRIC_TYPE` (`prefer-explicit`, `require-explicit`, `require-clean`)
- `AUDIO_PREFERRED_COUNTRIES` and `AUDIO_PREFERRED_FORMATS`
- `AUDIO_DEPRIORITIZE_COMMENTARY_RELEASES` (default: `true`)
- `AUDIO_IGNORE_INSTRUMENTAL_RELEASES` (default: `true`)
- `AUDIO_DOWNLOAD_ATTEMPT_THRESHOLD` (default: `10`)
- `AUDIO_DOWNLOAD_QUALITY_FALLBACK` (default: `true`)

Processing and output:

- `AUDIO_APPLY_BEETS` (default: `true`)
- `AUDIO_APPLY_REPLAYGAIN` (default: `true`)
- `AUDIO_BEETS_CUSTOM_CONFIG` (optional, path or inline YAML)
- `AUDIO_DEEMIX_CUSTOM_CONFIG` (optional, path or inline JSON)
- `AUDIO_RESULT_FILE_NAME` (default: `results.md`, empty disables)

State and paths:

- `AUDIO_WORK_PATH` (default: `/work`)
- `AUDIO_DATA_PATH` (default: `/data`)
- `AUDIO_SHARED_LIDARR_PATH` (default: `/sidecar-import`)
- `AUDIO_DEEMIX_ARL_FILE` (default: `/deemix_arl_token`)

AutoConfig toggles:

- `AUTOCONFIG_HOST`
- `AUTOCONFIG_MEDIAMANAGEMENT`
- `AUTOCONFIG_METADATA`
- `AUTOCONFIG_METADATAPROVIDER`
- `AUTOCONFIG_METADATAPROFILE`
- `AUTOCONFIG_NAMING`
- `AUTOCONFIG_QUALITYPROFILE`
- `AUTOCONFIG_UI`
- `AUTOCONFIG_CUSTOMFORMAT`
- `AUTOCONFIG_DOWNLOADCLIENT`

Each toggle has a corresponding `*_JSON` variable. See `Dockerfile` for current defaults and paths.

## Notes

- ARL token file must be owned by the runtime user and permissioned `0600`.
- Matching requires Deezer links in MusicBrainz release relations.
- Downloaded folder naming includes MusicBrainz release-group ID to improve Lidarr import reliability.
