# Development

## Run the tests

The unit tests use fake *arr APIs and temporary directories, so no Lidarr, Radarr, Sonarr or Deezer account is needed.
Run them from the repository root (the dev container sets `PYTHONPATH` and installs the packages):

```bash
pip install -r lidarr-sidecar/requirements.txt -r lidarr-musicvideo-sidecar/requirements.txt
export PYTHONPATH=$PWD
python -m unittest discover -s shared/python/tests -p 'test_*.py' -v
python -m unittest discover -s lidarr-sidecar/python/tests -p 'test_*.py' -v
python -m unittest discover -s lidarr-musicvideo-sidecar/python/tests -p 'test_*.py' -v
```

Lint and format with [ruff](https://docs.astral.sh/ruff/) (configured in `pyproject.toml`, including its security
rules):

```bash
pip install -r requirements-dev.txt
ruff check . && ruff format --check .
```

Or run the tests inside an image exactly as CI does. The Lidarr images run Debian's Python and the Radarr and Sonarr
images run Alpine's, so this also checks the code against the Python version each image ships:

```bash
docker buildx build -f lidarr-sidecar/Dockerfile --target test .
```

## Build the images

Build from the repository root, because every image includes `shared/python`:

```bash
docker build -f lidarr-sidecar/Dockerfile -t lidarr-sidecar:dev .
docker build -f lidarr-musicvideo-sidecar/Dockerfile -t lidarr-musicvideo-sidecar:dev .
docker build -f radarr-sidecar/Dockerfile -t radarr-sidecar:dev .
docker build -f sonarr-sidecar/Dockerfile -t sonarr-sidecar:dev .
```

Each `Dockerfile` has a `test` stage that copies the repository into the runtime image and runs the unit tests.
Multi-platform builds (`linux/amd64,linux/arm64`) need a Buildx builder with the `docker-container` driver and QEMU.

## Code layout

| Path | Contents |
| --- | --- |
| `shared/python/` | Entrypoint and supervisor, *arr API client, AutoConfig, AutoImport, config, logging and state helpers |
| `<sidecar>/services/one-time/` | Services run once at startup (AutoConfig) |
| `<sidecar>/services/persistent/` | Services kept running by the entrypoint |
| `<sidecar>/config/` | Default settings that AutoConfig applies to the *arr |
| `lidarr-sidecar/python/deemix_downloader/` | Lidarr wanted-list processing: MusicBrainz and Deezer lookups, matching, downloading, tagging and importing |
| `lidarr-musicvideo-sidecar/python/music_video_downloader/` | Music videos for Lidarr artists: MusicBrainz channel lookup, yt-dlp listing and download, title classification, library files |
| `<sidecar>/requirements.txt` | Pinned Python packages for the Lidarr images |
| `**/tests/` | Unit tests |

## Continuous integration and releases

All changes reach `main` through a pull request; the **Lint** and **Test** checks (ruff, and unit tests inside all
images on every platform) must pass and merges are squashed.

- **Every build of `main`** publishes each image as `:main` and `:sha-<commit>`, with an SBOM, BuildKit provenance and a
  GitHub build provenance attestation.
- **Vulnerability scanning** — Trivy scans each new `:main` image and the released `:latest` images weekly. Fixable
  HIGH and CRITICAL findings appear under **Security → Code scanning**; they do not block builds.
- **Dependencies** — the base images (pinned by digest), the Lidarr images' Python packages and the GitHub Actions (pinned to
  commit SHAs) are updated by [Renovate](https://docs.renovatebot.com/). Updates wait 3 days after publication, then
  merge automatically once **Test** passes.
- **Releases** are created automatically when a merge to `main` changes anything under `shared/`, `lidarr-sidecar/`,
  `lidarr-musicvideo-sidecar/`, `radarr-sidecar/` or `sonarr-sidecar/` other than documentation and tests. The version comes from the commit
  subject: `feat:` bumps the minor version, `<type>!:` or a `BREAKING CHANGE` footer bumps the major version, anything
  else (including Renovate updates) bumps the patch version. All images share the version: a release tags the
  images that were just published as `X.Y.Z`, `X.Y`, `X` and `latest`. To release manually, run the
  **Build, Test & Publish** workflow with a `release_tag` such as `v3.2.0`.
- If an unattended run on `main` fails, an issue titled **CI failed on main** is opened.
