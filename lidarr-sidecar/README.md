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
- Indexer (`services/persistent/Indexer.py`, opt-in)
  - Exposes authenticated Newznab album search and an NZBGet-compatible download-client bridge
  - Downloads only releases Lidarr grabs, enforces the persistent daily quota at the download boundary, and forces the selected Lidarr artist/album/release during import
- DeemixDownloader (`services/persistent/DeemixDownloader.py`)
  - Legacy wanted-list poller; disabled by default to avoid competing with Lidarr's indexer grabs
  - Resolves Deezer album IDs through MusicBrainz release relations
  - Validates candidate links (title, track count, lyric filters)
  - Enforces optional hard gates for Deezer redirect handling and UPC matching
  - Downloads via deemix, applies optional ReplayGain/Beets, and triggers Lidarr import
  - Supports import strategies: `scan` (DownloadedAlbumsScan) or `manual` (forced release via Manual Import API)
  - Writes `DEEZER_ALBUM_ID`, `DATE_DOWNLOADED`, and per-track MusicBrainz IDs to downloaded FLAC/MP3 files
- ManualImport (`services/persistent/ManualImport.py`)
  - Uses the same `shared/python/autoimport` mechanism as Radarr/Sonarr's AutoImport: watches `AUTOIMPORT_DROP_DIR` for marked folders, matches them against known Lidarr artist paths, then moves matched folders into Lidarr's watched import path for its own native import to pick up
  - Adds one Lidarr-specific step Radarr/Sonarr don't need: a pre-move hook tags the files (MusicBrainz IDs, ReplayGain, Beets) in place before the move, since audio needs this and video doesn't
  - Sets `DEEZER_ALBUM_ID` to `AUDIO_MANUAL_IMPORT_DEEZER_SENTINEL` (default `None`) instead of a real Deezer ID, so these tracks stay identifiable as manually-imported

## DeemixDownloader

When explicitly enabled, the legacy DeemixDownloader service turns Lidarr wanted albums into validated Deezer downloads. It loops on the wanted queue, evaluates candidate releases, downloads accepted matches, applies post-processing, and triggers Lidarr import. The new Indexer service is the default integration path when enabled.

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

## Lidarr Newznab integration

The opt-in Indexer service implements the Newznab search protocol and the NZBGet JSON-RPC download-client protocol supported by Lidarr 3.1.6. It does not connect to a Usenet server and does not provide real NZB content: the NZB is a validated, opaque handoff for a release already matched by the sidecar.

Searches resolve exact artist/album text against Lidarr's local library, then reuse the existing MusicBrainz-to-Deezer matching gates and ranking. Text-only searches try exact artist/album word boundaries; ambiguous matches are rejected. Artist-only searches return matched albums for that local artist. Searches do not consult the download quota, failure markers, or downloaded markers. No bitrate or quality is advertised because the final format is not known until the downloader selects it.

Lidarr's Newznab indexer configuration must have RSS disabled, while interactive and automatic search are enabled. Album-specific searches are supported; a generic RSS poll has no album identity and returns no releases.

### Verified behavior and limitations

The integration was exercised against isolated Lidarr 3.1.6.5079 instances using fake Deezer metadata and, for the import test, generated silent MP3s; no real Deezer credentials or audio were used. Interactive search and grab, automatic `AlbumSearch`, NZBGet `append`/`listgroups`/`history`, a forced import of all 12 Let It Be tracks with the selected artist/album/release IDs, and a failed-job `HistoryRedownload` retry were verified. Lidarr's automatic search command requires `albumIds: [<id>]`; sending a singular `albumId` fails.

Lidarr supplies a `drone` download ID with NZBGet `append`; the bridge persists and echoes it in `listgroups` and `history` so Lidarr can correlate the client item. Live validation confirmed a quota-waiting item appears in both the NZBGet-compatible queue and Lidarr's `/api/v1/queue`, with the same download ID and a “waiting for daily download quota” title. The real Deezer download path and other Lidarr versions have not been tested.

MusicBrainz requests are serialized within the sidecar process, honor numeric or HTTP-date `Retry-After` values, and share a 60-second budget per Newznab search. If MusicBrainz remains unavailable past that budget, the bridge returns a service-unavailable response instead of waiting until Lidarr disconnects or treating the failure as an empty search. This rate limit is process-local; separate sidecar processes do not coordinate with one another.

On 2026-11-13, an isolated Lidarr 3.1.6.5079 manual search for Olivia Rodrigo's `SOUR` returned one result from the configured Newznab indexer in under one second using cached metadata. The Lidarr queue remained empty and the test import directory had no files. This verified search delivery only; it did not grab or download anything, and no Deezer token was used.

### Setup and migration

1. Stop the old wanted-list poller before enabling the indexer. `SERVICE_DEEMIXDOWNLOADER_ENABLED` and `SERVICE_INDEXER_ENABLED` both default to `false`; leave the old poller disabled while using the new flow. Its `daily_download_state` writer does not coordinate with the new quota database.
2. Set `AUDIO_INDEXER_API_KEY` to a random secret of at least 32 characters and `AUDIO_INDEXER_CLIENT_PASSWORD` to a separate random secret of at least 16 characters. For example, generate values with `openssl rand -hex 32` and `openssl rand -hex 24`. Set `AUDIO_INDEXER_PUBLIC_URL` to the HTTP(S) URL reachable from Lidarr, with no path, query, or fragment. Set `SERVICE_INDEXER_ENABLED=true`.
3. Keep the Lidarr config XML mounted read-only and provide an ARL token file as for the existing downloader. Mount `AUDIO_WORK_PATH` persistently. Mount `AUDIO_SHARED_LIDARR_PATH` at the same path in both containers; the sidecar stages and tags files there before forced manual import.
4. Either set `AUTOCONFIG_DEEMIX_INDEXER=true` to idempotently create/update the dedicated download client and Newznab indexer on startup, or add them manually. Auto-configuration uses the names in `AUDIO_INDEXER_CLIENT_NAME` and `AUDIO_INDEXER_NAME`.
5. Add a **Download Client / NZBGet** pointing at `AUDIO_INDEXER_CLIENT_HOST` and port (`AUDIO_INDEXER_CLIENT_PORT`, defaulting to `AUDIO_INDEXER_PORT`, which defaults to `9797`), with `AUDIO_INDEXER_CLIENT_USERNAME` and `AUDIO_INDEXER_CLIENT_PASSWORD`. Set the music category to `Music` and leave “Add Paused” disabled. The NZBGet version/schema handshake was verified against Lidarr 3.1.6.5079.
6. Add an **Indexer / Newznab** with the public URL, API path `/api`, and `AUDIO_INDEXER_API_KEY`. Select audio categories (3000, 3010, 3030, 3040). Enable interactive and automatic search; disable RSS; set its `downloadClientId` to the NZBGet client created above. This binding prevents synthetic NZBs from being sent to a normal Usenet client.
7. Ensure the indexer URL and NZBGet client address are reachable from Lidarr over a private network. The bridge uses HTTP; do not expose it directly to the Internet. Use a trusted network or a TLS-terminating reverse proxy, and preserve the configured public URL when using a proxy.
8. Test the indexer and client in Lidarr before enabling automatic searches. Do not configure this indexer to use an ordinary Usenet client: its synthetic NZBs are only meaningful to the sidecar bridge.

The bridge keeps a grab queued while it downloads and runs Lidarr's forced Manual Import API with the chosen artist, album, and release IDs. It only reports success after that command completes and Lidarr registers track files, preventing the download client's normal completed-download scan from racing the forced import. The client history uses a unique, empty output path after manual import so it cannot rescan the shared staging root.

`AUDIO_DAILY_DOWNLOAD_LIMIT=0` is unlimited. Otherwise, each distinct album download reserves one slot immediately before download, releases it only when download failure is known, and records completion before import; an import failure therefore still counts. The local calendar day uses the container timezone (`TZ`). When full, searches still return matches and grabs remain in the NZBGet-compatible queue with a “waiting for daily download quota” title; the worker retries after the next local midnight. Pending reservations survive midnight and restart. Quota state lives under `AUDIO_WORK_PATH` in `daily_download_quota.sqlite3`. See the queue-view limitation above.

On first startup, the quota imports the existing `daily_download_state` count without modifying the legacy file. Stop the old poller before this migration. Corrupt/missing initialized quota state fails closed; do not delete the lock or database to reset the limit. The priority file is not read by the new flow and is left untouched; Lidarr-grabbed jobs all use the same quota. Legacy `AUDIO_PRIORITY_*` settings apply only if the old poller is explicitly re-enabled.

If a process restarts while a job is still downloading, the bridge requeues that attempt with its reservation. If the download had already completed but import recovery had not finished, the bridge marks the job for operator review rather than risking a second download; verify the files and complete the forced import manually. Lidarr-native “retry” of a failed NZBGet history entry starts a new quota attempt.

### New Indexer settings

- `SERVICE_INDEXER_ENABLED` (default: `false`)
- `SERVICE_DEEMIXDOWNLOADER_ENABLED` (default: `false`; legacy wanted-list poller)
- `AUDIO_INDEXER_API_KEY` (required; minimum 32 characters)
- `AUDIO_INDEXER_PUBLIC_URL` (required; reachable from Lidarr, no URL path/query/fragment)
- `AUDIO_INDEXER_BIND` (default: `0.0.0.0`)
- `AUDIO_INDEXER_PORT` (default: `9797`)
- `AUDIO_INDEXER_CLIENT_USERNAME` (default: `lidarr-sidecar`)
- `AUDIO_INDEXER_CLIENT_PASSWORD` (required; minimum 16 characters)
- `AUDIO_INDEXER_CLIENT_HOST` (default: `lidarr-sidecar`)
- `AUDIO_INDEXER_CLIENT_PORT` (default: `AUDIO_INDEXER_PORT`)
- `AUDIO_INDEXER_CLIENT_USE_SSL` (default: `false`)
- `AUDIO_INDEXER_CLIENT_NAME` (default: `Deemix NZBGet Bridge`)
- `AUDIO_INDEXER_NAME` (default: `Deemix Newznab Indexer`)
- `AUTOCONFIG_DEEMIX_INDEXER` (default: `false`; idempotently register the bound client and indexer)
- `AUDIO_DAILY_DOWNLOAD_LIMIT` (default: `0`, unlimited)

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

## ManualImport

Some albums simply aren't available on Deezer (out-of-print releases, self-released CDs, etc.). ManualImport lets you supply your own rips for an album Lidarr is already tracking (wanted/monitored), while still getting the same MusicBrainz/ReplayGain/Beets tagging DeemixDownloader applies - and it works the same way Radarr/Sonarr's AutoImport does: drop files in, get matched, get moved into Lidarr's watched import path, let Lidarr's own import pick them up. No explicit Manual Import API call is made; Lidarr identifies the exact release itself from the MusicBrainz tags this service just wrote (the same signal Lidarr's own `DownloadedAlbumsScan` already prefers over folder-name parsing).

### Why the folder name needs two parts

Radarr/Sonarr match a drop-folder name directly against a Movie/Series path (one API resource = one importable unit = one folder). Lidarr's Album API has **no path field at all** - only Artist does - so matching can only ever resolve to an *artist*, never a specific album. That means the folder name has to carry two things: the artist's exact on-disk folder name (for Lidarr-side matching), and a release-group MBID (for the tagging step to know which album). Artist folder names containing `--` are not supported by this naming format.

### Usage

1. Find the artist's folder name as Lidarr has it on disk, and the MusicBrainz release-group ID for the album (visible in Lidarr, or embedded in your library's folder naming convention).
2. Create a folder named `<AUTOIMPORT_IMPORT_MARKER><artist folder name>--<release-group-mbid>` (default marker: `import-`) inside `AUTOIMPORT_DROP_DIR`, e.g. `import-AC-DC--e197ccf5-96fc-3f99-bbcc-8d33be9bd498`.
   - To target a specific release/edition instead of whichever one Lidarr currently has monitored, append another `--<release-mbid>`.
3. Copy your ripped audio files (FLAC/MP3) into that folder - subfolders (e.g. per-disc) are flattened automatically.
4. On its next scan (`AUTOIMPORT_INTERVAL`), ManualImport matches the artist portion against Lidarr's known artist paths, tags the files in place, then moves the folder into `AUTOIMPORT_SHARED_PATH` (Lidarr's existing Blackhole-watched import path) for Lidarr to import on its own.
5. If no artist match is found, or the release-group MBID is invalid/tagging fails, the folder is set aside (unmarked, with an `IMPORT_STATUS.txt` on tagging failures) under `AUTOIMPORT_DROP_DIR` instead of being moved - same failure behavior as Radarr/Sonarr's AutoImport. Your files are tagged in place, never copied elsewhere.

`DEEZER_ALBUM_ID` is set to `AUDIO_MANUAL_IMPORT_DEEZER_SENTINEL` (default `None`) rather than a real Deezer ID, and `DATE_DOWNLOADED` is set to the current time - both let you distinguish manually-imported tracks from Deezer downloads later.

## Required Mounts

- Lidarr config XML:
  - `/path/to/lidarr/config.xml:/lidarr/config.xml:ro`
- Working path (state/cache/temp):
  - `/path/to/work:/work`
- Shared import path (also mounted in Lidarr):
  - `/path/to/shared/import:/sidecar-import`
- Manual import drop directory (optional, only needed to use ManualImport):
  - `/path/to/manual-import:/manual-import`
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
- `AUDIO_DOWNLOAD_ATTEMPT_THRESHOLD` (default: `10`; attempts per quality, accumulating distinct verified tracks between attempts)
- `AUDIO_DOWNLOAD_QUALITY_FALLBACK` (default: `true`)
- `AUDIO_IMPORT_STRATEGY` (default: `scan`; `manual` forces release selection via Lidarr Manual Import API)
- `AUDIO_IMPORT_MANUAL_FALLBACK_TO_SCAN` (default: `true`; if manual import rejects files, run DownloadedAlbumsScan as fallback)

ManualImport (see the section above for how the marker/MBID folder naming works):

- `SERVICE_MANUALIMPORT_ENABLED` (default: `false`; set to `true` only after configuring the ManualImport variables and mount below)
- `AUDIO_MANUAL_IMPORT_DEEZER_SENTINEL` (default: `None`; value written to DEEZER_ALBUM_ID for manually-imported tracks; no Radarr/Sonarr equivalent since they don't write this kind of tag)
- `AUDIO_MANUAL_IMPORT_CONVERT_TO_MP3` (default: `false`; when enabled, M4A/Opus/AAC/WAV files are converted to MP3 before tagging; when disabled, any non-FLAC/MP3 file is rejected)
- `AUTOIMPORT_DROP_DIR` (default: `/manual-import`)
- `AUTOIMPORT_IMPORT_MARKER` (default: `import-`; drop-folder name prefix)
- `AUTOIMPORT_INTERVAL` (default: `5m`)
- `AUTOIMPORT_SHARED_PATH` (default: `/sidecar-import`; same watched path as `AUDIO_SHARED_LIDARR_PATH`)
- `AUTOIMPORT_WORK_DIR` (default: `/work`; used for the artist-path cache)
- `AUTOIMPORT_CACHE_HOURS` (default: `1`; how long the artist-path cache is trusted before refreshing)
- `AUTOIMPORT_DOWNLOADCLIENT_NAME` (default: `lidarr-deemix-sidecar`, same as `AUDIO_DOWNLOADCLIENT_NAME` so no duplicate Blackhole client is created)
- `AUTOIMPORT_GROUP` (required, no default - the group ID your Lidarr container's media files use; ManualImport won't start without it)

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
- `AUTOCONFIG_QUALITYDEFINITION` (default `false`; no default JSON is shipped)
- `AUTOCONFIG_QUALITYPROFILE`
- `AUTOCONFIG_UI`
- `AUTOCONFIG_CUSTOMFORMAT`
- `AUTOCONFIG_DOWNLOADCLIENT`

Each toggle has a corresponding `*_JSON` variable. See `Dockerfile` for current defaults and paths.

Quality profile `formatItems` are matched to custom formats by `name`, so their `format` ids may differ from the
live ids. Custom formats not listed in a profile get score 0.

## Notes

- ARL token file must be owned by the runtime user and permissioned `0600`.
- Matching requires Deezer links in MusicBrainz release relations.
- Downloaded folder naming includes MusicBrainz release-group ID to improve Lidarr import reliability.
