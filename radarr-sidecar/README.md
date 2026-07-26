# Radarr Sidecar

Automates Radarr setup and import orchestration from a drop directory.

## Container Image

- Package: <https://github.com/scottfridwin/docker-arr-sidecars/pkgs/container/radarr-sidecar>
- Pull: `docker pull ghcr.io/scottfridwin/radarr-sidecar:latest`

## Services

- AutoConfig (`services/one-time/AutoConfig.py`)
  - Applies JSON-based configuration from `config/`
- AutoImport (`services/persistent/AutoImport.py`)
  - Watches a drop folder for marker-prefixed directories (default `import-`)
  - Matches target movie path in Radarr
  - Validates group ownership and group rw permissions
  - Moves files into shared import path and triggers `DownloadedMoviesScan`
  - Ensures a Blackhole download client exists

## Required Mounts

- Radarr config XML:
  - `/path/to/radarr/config.xml:/radarr/config.xml:ro`
- Drop folder:
  - `/path/to/drop:/drop`
- Work folder:
  - `/path/to/work:/work`
- Shared import path (also mounted in Radarr):
  - `/path/to/shared/import:/sidecar-import`

## Important Environment Variables

General:

- `ARR_CONFIG_PATH` (default: `/radarr/config.xml`)
- `ARR_HOST` (default: `radarr`)
- `ARR_SUPPORTED_API_VERSIONS` (default: `v3,v1`)
- `LOG_LEVEL` (default: `INFO`)
- `UMASK` (default: `0002`)

AutoImport:

- `AUTOIMPORT_GROUP` (required, numeric gid)
- `AUTOIMPORT_DROP_DIR` (default: `/drop`)
- `AUTOIMPORT_IMPORT_MARKER` (default: `import-`)
- `AUTOIMPORT_INTERVAL` (default: `5m`)
- `AUTOIMPORT_SHARED_PATH` (default: `/sidecar-import`)
- `AUTOIMPORT_WORK_DIR` (default: `/work`)
- `AUTOIMPORT_CACHE_HOURS` (default: `1`)
- `AUTOIMPORT_DOWNLOADCLIENT_NAME` (default: `radarr-sidecar`)

AutoConfig toggles:

- `AUTOCONFIG_HOST`
- `AUTOCONFIG_MEDIAMANAGEMENT`
- `AUTOCONFIG_NAMING`
- `AUTOCONFIG_QUALITYPROFILE`
- `AUTOCONFIG_REMOTEPATHMAPPING`
- `AUTOCONFIG_UI`
- `AUTOCONFIG_CUSTOMFORMAT`
- `AUTOCONFIG_DOWNLOADCLIENT`

Each toggle has a corresponding `*_JSON` variable. See `Dockerfile` for defaults.
