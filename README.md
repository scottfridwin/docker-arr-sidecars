# docker-arr-sidecars

[![Build and Publish](https://github.com/scottfridwin/docker-arr-sidecars/actions/workflows/build-publish.yml/badge.svg?branch=main)](https://github.com/scottfridwin/docker-arr-sidecars/actions/workflows/build-publish.yml)
[![Latest Release](https://img.shields.io/github/v/release/scottfridwin/docker-arr-sidecars?sort=semver)](https://github.com/scottfridwin/docker-arr-sidecars/releases)
[![License: GPL-3.0-only](https://img.shields.io/github/license/scottfridwin/docker-arr-sidecars)](LICENSE)

Sidecar containers for the *Arr ecosystem focused on reducing manual setup and repetitive import workflows.

- **Lidarr sidecar**: AutoConfig + Deezer/Deemix album automation with import orchestration
- **Radarr sidecar**: AutoConfig + drop-folder based auto-import
- **Sonarr sidecar**: AutoConfig + drop-folder based auto-import

Repository: https://github.com/scottfridwin/docker-arr-sidecars

## Published Images

| Sidecar | GHCR Package | Pull |
|---|---|---|
| Lidarr | https://github.com/scottfridwin/docker-arr-sidecars/pkgs/container/lidarr-sidecar | `docker pull ghcr.io/scottfridwin/lidarr-sidecar:latest` |
| Radarr | https://github.com/scottfridwin/docker-arr-sidecars/pkgs/container/radarr-sidecar | `docker pull ghcr.io/scottfridwin/radarr-sidecar:latest` |
| Sonarr | https://github.com/scottfridwin/docker-arr-sidecars/pkgs/container/sonarr-sidecar | `docker pull ghcr.io/scottfridwin/sonarr-sidecar:latest` |

## What Each Sidecar Does

| Sidecar | One-time services | Persistent services |
|---|---|---|
| Lidarr | AutoConfig | ARLChecker, DeemixDownloader |
| Radarr | AutoConfig | AutoImport |
| Sonarr | AutoConfig | AutoImport |

All sidecars use a shared Python entrypoint that:

- validates required environment and mounted config
- runs one-time services first
- supervises persistent services
- marks health via `/tmp/health`

## Quick Start (Compose)

```yaml
services:
  lidarr-sidecar:
    image: ghcr.io/scottfridwin/lidarr-sidecar:latest
    environment:
      - LOG_LEVEL=INFO
    volumes:
      - /path/to/lidarr/config.xml:/lidarr/config.xml:ro
      - /secure/path/deemix_arl_token:/deemix_arl_token:rw
      - /path/to/work:/work
      - /path/to/shared/import:/sidecar-import

  radarr-sidecar:
    image: ghcr.io/scottfridwin/radarr-sidecar:latest
    environment:
      - LOG_LEVEL=INFO
      - AUTOIMPORT_GROUP=1000
    volumes:
      - /path/to/radarr/config.xml:/radarr/config.xml:ro
      - /path/to/drop:/drop
      - /path/to/work:/work
      - /path/to/shared/import:/sidecar-import

  sonarr-sidecar:
    image: ghcr.io/scottfridwin/sonarr-sidecar:latest
    environment:
      - LOG_LEVEL=INFO
      - AUTOIMPORT_GROUP=1000
    volumes:
      - /path/to/sonarr/config.xml:/sonarr/config.xml:ro
      - /path/to/drop:/drop
      - /path/to/work:/work
      - /path/to/shared/import:/sidecar-import
```

## Sidecar Docs

- [lidarr-sidecar/README.md](lidarr-sidecar/README.md)
- [radarr-sidecar/README.md](radarr-sidecar/README.md)
- [sonarr-sidecar/README.md](sonarr-sidecar/README.md)

Each sidecar README includes:

- service behavior
- required mounts
- key environment variables
- package and pull references

## Tagging and Release Model

CI builds on pushes to `main` and publishes multi-arch images (`linux/amd64`, `linux/arm64`) to GHCR.

Image tags used by the workflow:

- `sha-<shortsha>` for commit builds
- `main` for branch tip builds
- `latest` and version tags (`vX.Y.Z`, `X.Y.Z`) when promoted via manual release dispatch

See workflow: [.github/workflows/build-publish.yml](.github/workflows/build-publish.yml)

## Development

Run unit tests locally:

```bash
python3 -m unittest discover -s shared/python/tests -p 'test_*.py' -v
python3 -m unittest discover -s lidarr-sidecar/python/tests -p 'test_*.py' -v
```

Build locally:

```bash
docker build -t lidarr-sidecar ./lidarr-sidecar
docker build -t radarr-sidecar ./radarr-sidecar
docker build -t sonarr-sidecar ./sonarr-sidecar
```

## Security Notes

- Lidarr ARL token file must be owned by the runtime user and permissioned `0600`.
- Radarr/Sonarr AutoImport expects `AUTOIMPORT_GROUP` to be set and enforces group ownership/permissions before moving files.

## Acknowledgements

This project was inspired by RandomNinjaAtk's [arr-scripts](https://github.com/RandomNinjaAtk/arr-scripts). Some logic was adapted and refactored into containerized sidecars.

## License

GPL-3.0-only. See [LICENSE](LICENSE).
