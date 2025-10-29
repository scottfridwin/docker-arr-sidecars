# docker-arr-sidecars

Sidecar containers for the *Arr ecosystem (Lidarr, Radarr, Sonarr). These sidecars automate common workflows such as initial configuration, import orchestration, and for Lidarr, automated Deezer downloads via Deemix with optional tagging/normalization.

Use them alongside your main *Arr containers to reduce manual clicks and glue logic.

## Acknowledgements

This project was inspired by the excellent work in RandomNinjaAtk's [arr-scripts](https://github.com/RandomNinjaAtk/arr-scripts). The original script logic there was adapted and refactored here to run as standalone containerized sidecars.

## What's here

- `lidarr-sidecar/` – Automates Lidarr with three services:
  - AutoConfig – applies opinionated Lidarr settings (media management, metadata provider/profile, track naming, UI) from JSON files
  - ARLChecker – validates a Deezer ARL token file on an interval (ownership and 0600 perms enforced)
  - DeemixDownloader – polls Lidarr's wanted list, finds best-matching Deezer releases, downloads with Deemix, optionally applies ReplayGain and Beets tagging, then triggers Lidarr import
- `radarr-sidecar/` – Automates Radarr with:
  - AutoConfig – applies media management, host, custom formats, UI, quality profiles, and naming from JSON
  - AutoImport – watches a "drop" folder for directories prefixed with an import marker (e.g., `import-My Movie (2024)`), moves them to the matching Radarr library path, and triggers import
- `sonarr-sidecar/` – Automates Sonarr with:
  - AutoConfig – same idea as Radarr (disabled by default in the Dockerfile)
  - AutoImport – same import flow as Radarr, but for series
- `shared/` – Common entrypoint and utilities used by all sidecars (logging, health, *Arr API helpers, state handling)

## How it works (at a glance)

- A shared entrypoint runs all service scripts in each sidecar and maintains a simple health file.
- Minimal changes required in the associated *Arr container; only a shared mount path for imports.
- Utilities provide:
  - Arr API discovery (URL base, API key, API version probing)
  - Robust request/retry handling and task-busy checks
  - Minimal key/value "state" across functions
  - Consistent logging with adjustable `LOG_LEVEL`

## Capabilities

### Lidarr sidecar

Services:

- AutoConfig
  - Updates Lidarr via API using bundled JSON files: media management, metadata provider/profile, track naming, and optional UI tweaks
- ARLChecker
  - Validates a Deezer ARL token read from `AUDIO_DEEMIX_ARL_FILE`
  - Enforces: file exists, owned by the running user, and mode 0600
  - Runs at `ARLUPDATE_INTERVAL` (e.g., `24h`)
- DeemixDownloader
  - Periodically scans the Lidarr wanted queue and fetches candidate releases from the Deezer API with caching and retry logic
  - Scores title matches with Levenshtein distance and rules (prefer special editions, deprioritize commentary, ignore instrumentals by keywords)
  - Downloads via Deemix using the ARL token
  - Optional: apply ReplayGain (`r128gain`) and Beets tagging
  - Adds a Usenet Blackhole download client in Lidarr pointing to a shared import folder if missing
  - Triggers Lidarr's `DownloadedAlbumsScan` for immediate import
  - Maintains working dirs (`/work/staging`, `/work/complete`, `/work/cache`) and a simple `notfound/` retry mechanism

#### Environment variables

| Variable | Default | Description |
|---|---|---|
| LOG_LEVEL | INFO | Log verbosity: TRACE, DEBUG, INFO, WARNING, ERROR |
| ARR_NAME | Lidarr | Friendly name (informational) |
| ARR_CONFIG_PATH | /lidarr/config.xml | Path to mounted Lidarr `config.xml` inside the sidecar |
| ARR_SUPPORTED_API_VERSIONS | v1 | API versions to probe in order |
| ARR_HOST | lidarr | Hostname/IP of Lidarr |
| ARR_PORT | (unset) | Optional external port override (reads from config if unset) |
| UMASK | (unset) | Process umask applied at start (e.g., 0002) |
| ARLUPDATE_INTERVAL | 24h | Interval between ARL token checks |
| AUDIO_APPLY_BEETS | true | Apply Beets tagging to downloads |
| AUDIO_APPLY_REPLAYGAIN | true | Apply ReplayGain tags via r128gain |
| AUDIO_CACHE_MAX_AGE_DAYS | 30 | Prune cache entries older than this many days |
| AUDIO_BEETS_CUSTOM_CONFIG | (unset) | Beets YAML custom config (path or inline YAML) |
| AUDIO_COMMENTARY_KEYWORDS | commentary,commentaries,directors commentary,audio commentary,with commentary,track by track | Keywords that mark commentary releases |
| AUDIO_DATA_PATH | /data | State path for `notfound/`, `downloaded/`, `failed/` |
| AUDIO_DEEMIX_CUSTOM_CONFIG | (unset) | Deemix JSON custom config (path or inline JSON) |
| AUDIO_DEEZER_API_RETRIES | 3 | Max retries for Deezer API calls |
| AUDIO_DEEZER_API_TIMEOUT | 30 | Deezer API timeout (seconds) |
| AUDIO_DEEMIX_ARL_FILE | /deemix_arl_token | Path to Deezer ARL token file (must be owned by container user and chmod 600) |
| AUDIO_DEPRIORITIZE_COMMENTARY_RELEASES | true | Prefer non-commentary releases when possible |
| AUDIO_DOWNLOADCLIENT_NAME | lidarr-deemix-sidecar | Name of Blackhole download client created in Lidarr |
| AUDIO_DOWNLOAD_ATTEMPT_THRESHOLD | 10 | Max attempts per album before skipping |
| AUDIO_DOWNLOAD_CLIENT_TIMEOUT | 10m | Timeout for Deemix download step |
| AUDIO_FAILED_ATTEMPT_THRESHOLD | 6 | Fail threshold per album across runs |
| AUDIO_IGNORE_INSTRUMENTAL_RELEASES | true | Skip instrumental releases by keyword |
| AUDIO_INSTRUMENTAL_KEYWORDS | Instrumental,Score | Instrumental keywords list |
| AUDIO_INTERVAL | 15m | Main loop sleep interval for downloader |
| AUDIO_LYRIC_TYPE | prefer-explicit | Lyric preference: prefer-explicit, prefer-clean, both |
| AUDIO_MATCH_DISTANCE_THRESHOLD | 3 | Max Levenshtein distance for title matching |
| AUDIO_PREFER_SPECIAL_EDITIONS | true | Prefer deluxe/special editions when tied |
| AUDIO_REQUIRE_QUALITY | true | Require target quality (vs. accept best-effort) |
| AUDIO_RETRY_NOTFOUND_DAYS | 90 | Give up-not-found entries a retry after this many days |
| AUDIO_SHARED_LIDARR_PATH | /sidecar-import | Shared import path watched by Lidarr (Blackhole) |
| AUDIO_TAGS | deemix | Comma-separated tags to ensure exist in Lidarr |
| AUDIO_TITLE_REPLACEMENTS_FILE | /app/config/album_title_replacements.json | Title normalization map (JSON) |
| AUDIO_WORK_PATH | /work | Working directory for staging/complete/cache |
| AUTOCONFIG_MEDIA_MANAGEMENT | true | Apply media management settings from JSON |
| AUTOCONFIG_MEDIA_MANAGEMENT_JSON | /app/config/media_management.json | Media management JSON path |
| AUTOCONFIG_METADATA_CONSUMER | false | Apply metadata consumer settings |
| AUTOCONFIG_METADATA_CONSUMER_JSON | /app/config/metadata_consumer.json | Metadata consumer JSON path |
| AUTOCONFIG_METADATA_PROVIDER | true | Apply metadata provider settings |
| AUTOCONFIG_METADATA_PROVIDER_JSON | /app/config/metadata_provider.json | Metadata provider JSON path |
| AUTOCONFIG_LIDARR_UI | false | Apply UI settings |
| AUTOCONFIG_LIDARR_UI_JSON | /app/config/lidarr_ui.json | UI JSON path |
| AUTOCONFIG_METADATA_PROFILE | true | Apply metadata profiles |
| AUTOCONFIG_METADATA_PROFILE_JSON | /app/config/metadata_profile.json | Metadata profile JSON path |
| AUTOCONFIG_TRACK_NAMING | true | Apply track naming settings |
| AUTOCONFIG_TRACK_NAMING_JSON | /app/config/track_naming.json | Track naming JSON path |

### Radarr sidecar

Services:

- AutoConfig – sends bundled JSONs for: media management, host, custom formats, UI, quality profiles, naming
- AutoImport – watches a drop directory for folders beginning with an import marker and:
  - Attempts to match the folder (minus marker) to an existing Radarr movie path
  - Verifies group ownership and group rw permissions for all files (`AUTOIMPORT_GROUP` is required)
  - Moves the folder into the matched library path under `AUTOIMPORT_SHARED_PATH`
  - Triggers Radarr's `DownloadedMoviesScan` for import
  - Adds tags and a Blackhole download client mapped to your shared import folder if missing

#### Environment variables

| Variable | Default | Description |
|---|---|---|
| UMASK | 0002 | Process umask applied at start |
| LOG_LEVEL | INFO | Log verbosity |
| ARR_NAME | radarr | Friendly name (informational) |
| ARR_CONFIG_PATH | /radarr/config.xml | Path to mounted Radarr `config.xml` inside the sidecar |
| ARR_SUPPORTED_API_VERSIONS | v3,v1 | API versions to probe in order |
| ARR_HOST | radarr | Hostname/IP of Radarr |
| ARR_PORT | (unset) | Optional external port override |
| AUTOCONFIG_MEDIAMANAGEMENT | true | Apply media management settings from JSON |
| AUTOCONFIG_MEDIAMANAGEMENT_JSON | /app/config/mediamanagement.json | Media management JSON path |
| AUTOCONFIG_HOST | true | Apply host settings |
| AUTOCONFIG_HOST_JSON | /app/config/host.json | Host JSON path |
| AUTOCONFIG_CUSTOMFORMAT | true | Apply custom format(s) |
| AUTOCONFIG_CUSTOMFORMAT_JSON | /app/config/customformat.json | Custom format JSON path |
| AUTOCONFIG_UI | true | Apply UI settings |
| AUTOCONFIG_UI_JSON | /app/config/ui.json | UI JSON path |
| AUTOCONFIG_QUALITYPROFILE | true | Apply quality profile(s) |
| AUTOCONFIG_QUALITYPROFILE_JSON | /app/config/qualityprofile.json | Quality profile JSON path |
| AUTOCONFIG_NAMING | true | Apply naming settings |
| AUTOCONFIG_NAMING_JSON | /app/config/naming.json | Naming JSON path |
| AUTOIMPORT_CACHE_HOURS | 1 | Cache lifetime for path list (hours) |
| AUTOIMPORT_DROP_DIR | /drop | Directory scanned for `import-` prefixed folders |
| AUTOIMPORT_DOWNLOADCLIENT_NAME | radarr-sidecar | Blackhole client name created if missing |
| AUTOIMPORT_GROUP | (unset) | REQUIRED. Numeric gid expected on files for permission checks |
| AUTOIMPORT_IMPORT_MARKER | import- | Prefix marking folders to import |
| AUTOIMPORT_INTERVAL | 5m | Scan interval for drop directory |
| AUTOIMPORT_SHARED_PATH | /sidecar-import | Library root seen by Radarr |
| AUTOIMPORT_TAGS | autoimport | Tags ensured to exist in Radarr |
| AUTOIMPORT_WORK_DIR | /work | Working directory for caches |

### Sonarr sidecar

Services:

- AutoConfig – same pattern as Radarr (defaults disabled in Dockerfile)
- AutoImport – same behavior as Radarr but for series, using Sonarr's `DownloadedSeriesScan`

#### Environment variables

| Variable | Default | Description |
|---|---|---|
| UMASK | 0002 | Process umask applied at start |
| LOG_LEVEL | INFO | Log verbosity |
| ARR_NAME | sonarr | Friendly name (informational) |
| ARR_CONFIG_PATH | /sonarr/config.xml | Path to mounted Sonarr `config.xml` inside the sidecar |
| ARR_SUPPORTED_API_VERSIONS | v3,v1 | API versions to probe in order |
| ARR_HOST | sonarr | Hostname/IP of Sonarr |
| ARR_PORT | (unset) | Optional external port override |
| AUTOCONFIG_MEDIAMANAGEMENT | false | Apply media management settings from JSON |
| AUTOCONFIG_MEDIAMANAGEMENT_JSON | /app/config/mediamanagement.json | Media management JSON path |
| AUTOCONFIG_HOST | false | Apply host settings |
| AUTOCONFIG_HOST_JSON | /app/config/host.json | Host JSON path |
| AUTOCONFIG_CUSTOMFORMAT | false | Apply custom format(s) |
| AUTOCONFIG_CUSTOMFORMAT_JSON | /app/config/customformat.json | Custom format JSON path |
| AUTOCONFIG_UI | false | Apply UI settings |
| AUTOCONFIG_UI_JSON | /app/config/ui.json | UI JSON path |
| AUTOCONFIG_QUALITYPROFILE | false | Apply quality profile(s) |
| AUTOCONFIG_QUALITYPROFILE_JSON | /app/config/qualityprofile.json | Quality profile JSON path |
| AUTOCONFIG_NAMING | false | Apply naming settings |
| AUTOCONFIG_NAMING_JSON | /app/config/naming.json | Naming JSON path |
| AUTOIMPORT_CACHE_HOURS | 1 | Cache lifetime for path list (hours) |
| AUTOIMPORT_DROP_DIR | /drop | Directory scanned for `import-` prefixed folders |
| AUTOIMPORT_DOWNLOADCLIENT_NAME | sonarr-sidecar | Blackhole client name created if missing |
| AUTOIMPORT_GROUP | (unset) | REQUIRED. Numeric gid expected on files for permission checks |
| AUTOIMPORT_IMPORT_MARKER | import- | Prefix marking folders to import |
| AUTOIMPORT_INTERVAL | 5m | Scan interval for drop directory |
| AUTOIMPORT_SHARED_PATH | /sidecar-import | Library root seen by Sonarr |
| AUTOIMPORT_TAGS | autoimport | Tags ensured to exist in Sonarr |
| AUTOIMPORT_WORK_DIR | /work | Working directory for caches |

## Volumes you'll typically mount

- The *Arr config file into the sidecar:
  - Lidarr: `-v /path/to/lidarr/config.xml:/lidarr/config.xml:ro`
  - Radarr: `-v /path/to/radarr/config.xml:/radarr/config.xml:ro`
  - Sonarr: `-v /path/to/sonarr/config.xml:/sonarr/config.xml:ro`
- A shared import folder both the sidecar and *Arr see (Blackhole watch):
  - `-v /some/shared/import:/sidecar-import`
- A working directory for caches/temp/state:
  - `-v /path/to/work:/work`
- Lidarr only: ARL token file with strict perms and ownership:
  - `-v /secure/path/deemix_arl_token:/deemix_arl_token:rw` (must be owned by the container user and `chmod 600`)

## Example: docker compose snippets

These are minimal examples; adapt paths and network addresses to your setup.

```yaml
services:
 lidarr-sidecar:
  image: ghcr.io/scottfridwin/lidarr-sidecar:latest
  container_name: lidarr-sidecar
  environment:
   - LOG_LEVEL=INFO
  volumes:
   - /path/to/lidarr/config.xml:/lidarr/config.xml:ro
   - /secure/path/deemix_arl_token:/deemix_arl_token:rw
   - /path/to/work:/work
   - /path/to/shared/import:/sidecar-import
  depends_on:
   - lidarr

 radarr-sidecar:
  image: ghcr.io/scottfridwin/radarr-sidecar:latest
  container_name: radarr-sidecar
  environment:
   - LOG_LEVEL=INFO
   - AUTOIMPORT_GROUP=1000   # target group id for permission checks
  volumes:
   - /path/to/radarr/config.xml:/radarr/config.xml:ro
   - /path/to/drop:/drop
   - /path/to/work:/work
   - /path/to/shared/import:/sidecar-import
  depends_on:
   - radarr

 sonarr-sidecar:
  image: ghcr.io/scottfridwin/sonarr-sidecar:latest
  container_name: sonarr-sidecar
  environment:
   - LOG_LEVEL=INFO
   - AUTOIMPORT_GROUP=1000   # target group id for permission checks
  volumes:
   - /path/to/sonarr/config.xml:/sonarr/config.xml:ro
   - /path/to/drop:/drop
   - /path/to/work:/work
   - /path/to/shared/import:/sidecar-import
  depends_on:
   - sonarr
```

Notes:

- The sidecars discover the correct *Arr API version automatically from `ARR_SUPPORTED_API_VERSIONS` defaults.
- If your *Arr instances run with a URL base, it's auto-detected from the mounted `config.xml`.
- For Radarr/Sonarr AutoImport, create the "drop" folder and place directories there named like `import-<exact movie or series folder name>`.

## Build locally

Build any sidecar with Docker:

```bash
docker build -t lidarr-sidecar ./lidarr-sidecar
docker build -t radarr-sidecar ./radarr-sidecar
docker build -t sonarr-sidecar ./sonarr-sidecar
```

## Security and permissions

- Lidarr ARL token file must be owned by the container's user (default root unless you override) and set to `0600`.
- Radarr/Sonarr AutoImport validates that all files in a candidate import folder have the expected group id and group read/write perms. Set `AUTOIMPORT_GROUP` to the numeric gid your media files should use.

## FAQ

- Can I disable parts of AutoConfig? Yes. Each `AUTOCONFIG_*` flag can be toggled per sidecar; see the Dockerfiles for defaults and the `config/` JSON files.
- How do I customize Deemix/Beets? Provide your own JSON/YAML via `AUDIO_DEEMIX_CUSTOM_CONFIG`/`AUDIO_BEETS_CUSTOM_CONFIG` (path or inline content). Custom settings merge with the defaults.
- Where do downloaded files go for Lidarr? Into the shared folder you map to `AUDIO_SHARED_LIDARR_PATH`. The sidecar notifies Lidarr to import from there.

## License

This project is licensed under the GNU General Public License v3.0 (GPL-3.0). See `LICENSE` for the full text. Source files include SPDX identifiers (`GPL-3.0-only`). Portions of logic were adapted from RandomNinjaAtk's [arr-scripts](https://github.com/RandomNinjaAtk/arr-scripts).

---

If you spot gaps or want additional knobs documented, open an issue or PR. Happy automating!
