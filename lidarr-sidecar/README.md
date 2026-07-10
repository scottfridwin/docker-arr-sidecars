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
  - Enforces optional hard gates for Deezer redirect handling and UPC matching
  - Downloads via deemix, applies optional ReplayGain/Beets, and triggers Lidarr import
  - Supports import strategies: `scan` (DownloadedAlbumsScan) or `manual` (forced release via Manual Import API)
  - Writes `DEEZER_ALBUM_ID`, `DATE_DOWNLOADED`, and per-track MusicBrainz IDs to downloaded FLAC/MP3 files

## DeemixDownloader

The DeemixDownloader service is responsible for turning Lidarr wanted albums into validated Deezer downloads. It loops on the wanted queue, evaluates candidate releases, downloads accepted matches, applies post-processing, and triggers Lidarr import.

### Matching workflow

1. Pull wanted albums from Lidarr and build candidate releases from MusicBrainz release relations.
2. Keep only candidates that include a Deezer album link.
3. Apply ranking and preference logic to choose evaluation order (official status, commentary/instrumental preferences, country/format preference, track count).
4. For each candidate, call Deezer and apply hard gates:
   - Deezer album must exist and be fetchable.
   - Redirect gate: when AUDIO_REQUIRE_NON_REDIRECT_DEEZER is true (default), redirected Deezer IDs are rejected.
   - UPC gate: when AUDIO_REQUIRE_UPC_MATCH is true (default), MusicBrainz barcode must match Deezer UPC after leading-zero normalization.
   - Lyric type requirement, title sanity checks, and track-count sanity checks must pass.
5. First candidate that passes all active gates is selected for download.
6. Downloaded files are tagged, optionally processed by ReplayGain and Beets, moved to import, and Lidarr is notified.
7. If `AUDIO_IMPORT_STRATEGY=manual`, the sidecar calls Lidarr Manual Import and forces the selected artist/album/release. If rejected, it can optionally fall back to scan import.

### results.md and missing.md

The downloader writes two complementary files to AUDIO_WORK_PATH:

- results.md (configured by AUDIO_RESULT_FILE_NAME)
  - Append-only match history.
  - Includes timestamp, artist/album identifiers, selected release ID, and Deezer ID.
  - Useful for auditing what was attempted and what matched over time.

- missing.md (configured by AUDIO_MISSING_RESULT_FILE_NAME)
  - Current-state view of albums that are still unmatched.
  - Stores the latest no-match reason per album (for example: no Deezer link, redirect gate rejection, UPC mismatch, fetch failure, title/track sanity failure).
  - Entries are updated on each no-match attempt and removed automatically once an album is successfully downloaded.

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
- `AUDIO_REQUIRE_NON_REDIRECT_DEEZER` (default: `true`, reject redirected Deezer IDs)
- `AUDIO_REQUIRE_UPC_MATCH` (default: `true`, require MusicBrainz barcode and Deezer UPC to match after stripping leading zeros)
- `AUDIO_DOWNLOAD_ATTEMPT_THRESHOLD` (default: `10`)
- `AUDIO_DOWNLOAD_QUALITY_FALLBACK` (default: `true`)
- `AUDIO_IMPORT_STRATEGY` (default: `scan`; `manual` forces release selection via Lidarr Manual Import API)
- `AUDIO_IMPORT_MANUAL_FALLBACK_TO_SCAN` (default: `true`; if manual import rejects files, run DownloadedAlbumsScan as fallback)

Processing and output:

- `AUDIO_APPLY_BEETS` (default: `true`)
- `AUDIO_APPLY_REPLAYGAIN` (default: `true`)
- `AUDIO_BEETS_CUSTOM_CONFIG` (optional, path or inline YAML)
- `AUDIO_DEEMIX_CUSTOM_CONFIG` (optional, path or inline JSON)
- `AUDIO_RESULT_FILE_NAME` (default: `results.md`, empty disables)
- `AUDIO_MISSING_RESULT_FILE_NAME` (default: `missing.md`, empty disables). Written in the same work path as results with per-album no-match reason summaries.

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
