# docker-arr-sidecars

[![Build](https://img.shields.io/github/actions/workflow/status/scottfridwin/docker-arr-sidecars/build.yml?branch=main&label=build)](https://github.com/scottfridwin/docker-arr-sidecars/actions/workflows/build.yml)
[![Release](https://img.shields.io/github/v/release/scottfridwin/docker-arr-sidecars?sort=semver)](https://github.com/scottfridwin/docker-arr-sidecars/releases/latest)
[![License](https://img.shields.io/github/license/scottfridwin/docker-arr-sidecars)](LICENSE)

Sidecar containers for [Lidarr](https://lidarr.audio/), [Radarr](https://radarr.video/) and
[Sonarr](https://sonarr.tv/) that remove manual setup and repetitive import work.

- **Lidarr sidecar**: applies your settings at startup, and downloads wanted albums from Deezer (matched through
  MusicBrainz links) and imports them
- **Radarr sidecar**: applies your settings at startup, and imports movies dropped into a folder
- **Sonarr sidecar**: applies your settings at startup, and imports series dropped into a folder

> [!NOTE]
> **AI disclosure:** This project is built and maintained with substantial help from AI coding assistants (GitHub
> Copilot). AI is used to write and modify the code, tests, documentation and CI configuration, and to manage the
> repository. Dependency updates are merged and released automatically, without human review, when the automated
> tests pass. Review the code and test it in your own environment before relying on it.

## Images

| Sidecar | Image | Docs |
| --- | --- | --- |
| Lidarr | [`ghcr.io/scottfridwin/lidarr-sidecar`](https://github.com/scottfridwin/docker-arr-sidecars/pkgs/container/lidarr-sidecar) | [lidarr-sidecar/README.md](lidarr-sidecar/README.md) |
| Radarr | [`ghcr.io/scottfridwin/radarr-sidecar`](https://github.com/scottfridwin/docker-arr-sidecars/pkgs/container/radarr-sidecar) | [radarr-sidecar/README.md](radarr-sidecar/README.md) |
| Sonarr | [`ghcr.io/scottfridwin/sonarr-sidecar`](https://github.com/scottfridwin/docker-arr-sidecars/pkgs/container/sonarr-sidecar) | [sonarr-sidecar/README.md](sonarr-sidecar/README.md) |

All three images are built for `linux/amd64` and `linux/arm64` and share one version number. Each release is tagged
`X.Y.Z`, `X.Y`, `X` and `latest`; pin a major version such as `:3` to get fixes without breaking changes. Every image
has an SBOM and a signed build provenance attestation.

## What each sidecar does

| Sidecar | At startup | Runs continuously |
| --- | --- | --- |
| Lidarr | AutoConfig | ARLChecker, DeemixDownloader (and ManualImport if enabled) |
| Radarr | AutoConfig | AutoImport |
| Sonarr | AutoConfig | AutoImport |

All sidecars use the same entrypoint, which:

- checks the required environment and mounted config
- runs the startup services first, then starts the continuous services
- stops the container if a continuous service exits, so Docker's restart policy starts it fresh
- reports a failed startup through Docker's health check (*unhealthy*) instead of a restart loop

## Quick start

The sidecars read the API key from the *arr's `config.xml`, so mount it read-only. They run as UID/GID `1000` by
default, never as root; set `user:` to the same user and group as the *arr so imported files get the right owner.

```yaml
services:
  radarr-sidecar:
    image: ghcr.io/scottfridwin/radarr-sidecar:3
    user: "1000:1000"
    read_only: true
    tmpfs:
      - /tmp:uid=1000,gid=1000
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    environment:
      - ARR_HOST=radarr
      - AUTOIMPORT_GROUP=1000
    volumes:
      - /path/to/radarr/config.xml:/radarr/config.xml:ro
      - /path/to/drop:/drop
      - /path/to/work:/work
      - /path/to/shared/import:/sidecar-import
    restart: unless-stopped
```

The Sonarr sidecar is the same with `sonarr` in place of `radarr`. The Lidarr sidecar also needs the Deezer ARL token
file; see [lidarr-sidecar/README.md](lidarr-sidecar/README.md) for its mounts and settings.

## Security notes

- The Lidarr ARL token file must be owned by the container's user and have mode `0600`; the sidecar refuses to start
  otherwise.
- Radarr and Sonarr AutoImport need `AUTOIMPORT_GROUP` and check group ownership and permissions before moving files.
- API keys, passwords and tokens are masked in logs.
- See [SECURITY.md](SECURITY.md) for reporting vulnerabilities and verifying images.

## Further reading

- [Development](docs/development.md)

## Acknowledgements

This project was inspired by RandomNinjaAtk's [arr-scripts](https://github.com/RandomNinjaAtk/arr-scripts). Some logic
was adapted and refactored into containerized sidecars.

## License

[GPL-3.0](LICENSE)
