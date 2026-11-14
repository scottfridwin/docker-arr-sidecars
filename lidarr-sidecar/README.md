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
  - Legacy wanted-list poller; enabled by default for compatibility with existing installations
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

The legacy DeemixDownloader service turns Lidarr wanted albums into validated Deezer downloads. It loops on the wanted queue, evaluates candidate releases, downloads accepted matches, applies post-processing, and triggers Lidarr import. Disable it explicitly when enabling the Indexer service.

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

Searches resolve artist and album names against Lidarr's library and offer eligible MusicBrainz release/Deezer album pairs. Ambiguous local matches are rejected. Each release needs a Deezer album link and must pass the configured redirect, UPC, lyric-type, title and track-count gates. A missing Deezer artist link produces a warning but does not prevent album discovery. Searches are independent of the download quota and legacy download/failure markers.

Results identify the edition, track count, Deezer ID and Lidarr release ID. Review editions or configure Lidarr custom formats to control selection: ranking preferences do not hide other eligible editions, including radio specials, and Lidarr's decision criteria take precedence. Instrumental exclusion falls back to instrumental releases if no other release is available. Conservative title and identity checks can exclude valid matches; exclusions are logged. The advertised size and age are placeholders, and quality is unknown until download.

Lidarr's Newznab indexer configuration must have RSS disabled, while interactive and automatic search are enabled. Album-specific searches are supported; a generic RSS poll has no album identity and returns no releases.

### Search behavior

Searches run in a persistent, deduplicated background queue with two workers. Slow searches can still delay later searches when both workers are busy. The indexer waits up to 10 seconds for a result; if it is still running, it returns an empty RSS response and logs that the search is warming, avoiding an HTTP error that could make Lidarr disable the indexer. Ambiguous searches are also logged and returned as empty RSS responses. Once the sidecar logs a warming search as completed, retry it manually in Lidarr, or opt in to automatic retries below. Searches that never reached the sidecar must also be retried. Other upstream or bridge failures still return HTTP errors and may make Lidarr temporarily disable the indexer. Completed search responses are reused for five minutes, including across sidecar restarts. Pending work resumes after a sidecar restart.

Set `AUDIO_INDEXER_AUTO_RETRY_SEARCHES=true` to reissue warmed searches with matching albums through Lidarr after they complete. **Lidarr treats these as user-invoked searches, which can bypass delay profiles and automatically grab releases even when the original search was interactive.** The sidecar waits for active Lidarr search commands to finish before submitting a retry. If submission is interrupted or its outcome is uncertain, it logs an error and does not automatically resubmit; inspect Lidarr before retrying manually. The option defaults to `false`.

MusicBrainz requests are serialized and honor `Retry-After`. Transient MusicBrainz and Deezer failures are retried in the background, so a prolonged outage can leave a search warming indefinitely. Metadata is cached; newly added MusicBrainz links may not appear immediately.

The integration has been tested with Lidarr 3.1.6.5079; other versions have not been verified. See [indexer development context](../docs/lidarr-indexer-development.md) for implementation and test history.

### Setup and migration

1. Stop the old wanted-list poller before enabling the indexer. Set `SERVICE_DEEMIXDOWNLOADER_ENABLED=false` and `SERVICE_INDEXER_ENABLED=true`; the legacy poller defaults to `true` and the indexer to `false`. Both services refuse to run together because the legacy `daily_download_state` writer does not coordinate with the new quota database.
2. Set `AUDIO_INDEXER_API_KEY` to a random secret of at least 32 characters and `AUDIO_INDEXER_CLIENT_PASSWORD` to a separate random secret of at least 16 characters. Alternatively, mount secret files and set `AUDIO_INDEXER_API_KEY_FILE` and `AUDIO_INDEXER_CLIENT_PASSWORD_FILE` to their paths. For example, generate values with `openssl rand -hex 32` and `openssl rand -hex 24`. Set `AUDIO_INDEXER_PUBLIC_URL` to the HTTP(S) URL reachable from Lidarr, with no path, query, or fragment. Set `SERVICE_INDEXER_ENABLED=true`.
3. Keep the Lidarr config XML mounted read-only and provide an ARL token file as for the existing downloader. Mount `AUDIO_WORK_PATH` and `AUDIO_DATA_PATH` persistently and writable. Mount `AUDIO_SHARED_LIDARR_PATH` at the same path in both containers; the sidecar stages and tags files there before forced manual import.
4. Either set `AUTOCONFIG_DEEMIX_INDEXER=true` to idempotently create/update the dedicated download client and Newznab indexer on startup, or add them manually. Auto-configuration runs after the bridge starts listening and before its download worker starts. It uses the names in `AUDIO_INDEXER_CLIENT_NAME` and `AUDIO_INDEXER_NAME`; a configuration failure stops the indexer service and marks the container unhealthy.
5. If configuring manually, add a **Download Client / NZBGet** pointing at `AUDIO_INDEXER_CLIENT_HOST` and port (`AUDIO_INDEXER_CLIENT_PORT`, defaulting to `AUDIO_INDEXER_PORT`, which defaults to `9797`), with `AUDIO_INDEXER_CLIENT_USERNAME` and `AUDIO_INDEXER_CLIENT_PASSWORD`. Set the music category to `Music` and leave “Add Paused” disabled.
6. If configuring manually, add an **Indexer / Newznab** with the public URL, API path `/api`, and `AUDIO_INDEXER_API_KEY`. Select audio categories (3000, 3010, 3030, 3040). Enable interactive and automatic search; disable RSS; set its `downloadClientId` to the NZBGet client created above. This binding prevents synthetic NZBs from being sent to a normal Usenet client.
7. Ensure the indexer URL and NZBGet client address are reachable from Lidarr over a private network. The bridge uses HTTP; do not expose it directly to the Internet. Use a trusted network or a TLS-terminating reverse proxy, and preserve the configured public URL when using a proxy.
8. Test the indexer and client in Lidarr before enabling automatic searches. Do not configure this indexer to use an ordinary Usenet client: its synthetic NZBs are only meaningful to the sidecar bridge.

For Docker Compose file-backed secrets, a minimal sidecar configuration is:

```yaml
secrets:
  lidarr_indexer_api_key:
    file: /path/to/lidarr_indexer_api_key
  lidarr_indexer_client_password:
    file: /path/to/lidarr_indexer_client_password

services:
  lidarr-sidecar:
    secrets:
      - lidarr_indexer_api_key
      - lidarr_indexer_client_password
    environment:
      - AUDIO_INDEXER_API_KEY_FILE=/run/secrets/lidarr_indexer_api_key
      - AUDIO_INDEXER_CLIENT_PASSWORD_FILE=/run/secrets/lidarr_indexer_client_password
```

Ensure both files are readable by the sidecar's configured user. Set either a credential or its `_FILE` setting, not both. Files must be UTF-8; trailing newlines are removed. A missing, unreadable, invalid, or too-short secret prevents startup. Restart the sidecar after changing a secret so the bridge and Lidarr configuration use the same credentials. Auto-configuration also stores the credentials in Lidarr. Docker Compose file-backed secrets are host files, so protect their permissions and backups.

The bridge keeps a grab queued while it downloads and runs Lidarr's forced Manual Import API with the chosen artist, album, and release IDs. It only reports success after that command completes and Lidarr registers track files, preventing the download client's normal completed-download scan from racing the forced import. The client history uses a unique, empty output path after manual import so it cannot rescan the shared staging root.

### Quota and recovery

`AUDIO_DAILY_DOWNLOAD_LIMIT=0` is unlimited. Otherwise, each distinct album download reserves one slot immediately before download, releases it only when download failure is known, and records completion before import; an import failure therefore still counts. The local calendar day uses the container timezone (`TZ`). When full, searches still return matches and grabs remain in the NZBGet-compatible queue with a “waiting for daily download quota” title; the worker retries after the next local midnight. Pending reservations survive midnight and restart. Quota state lives under `AUDIO_WORK_PATH` in `daily_download_quota.sqlite3`.

On startup and when used, the quota reconciles the legacy `daily_download_state` count and mirrors completed downloads back to that file. Stop one service before switching modes; they do not coordinate concurrent writes. The updated legacy poller refuses to start while indexer reservations remain unresolved. Before rolling back to an older image, stop the indexer and resolve or conservatively remove all uncertain jobs first: older pollers cannot check reservations. Older pollers also do not record downloads while their limit is unlimited, so avoid switching back from an older image that downloaded with `AUDIO_DAILY_DOWNLOAD_LIMIT=0` until the next local day. Corrupt/missing initialized quota state fails closed; do not delete the lock or database to reset the limit. The priority file is not read or modified by the new flow; Lidarr-grabbed jobs all use the same quota. Legacy `AUDIO_PRIORITY_*` settings apply only if the old poller is explicitly re-enabled.

Queued and quota-waiting jobs may be removed; removal is refused while downloading or importing because the bridge cannot safely cancel the operation. Interrupted or uncertain downloads and unsuccessful imports appear in the queue as “needs manual recovery” and are not automatically retried. To retry, remove the item in Lidarr with **Remove from Download Client** enabled and blocklisting disabled. The bridge conservatively charges any unresolved reservation to the removal day before clearing the item; an already completed download is not charged twice. With a limit of one, the retry may therefore wait until the next local day. If quota state is unavailable, removal fails rather than releasing an uncertain reservation. Do not edit or delete the quota database.

While any job needs recovery, new downloads are paused to protect audio that may remain in `/work/staging`; searches continue. Review or move any files in that staging directory before removing the recovery job or switching to the legacy downloader, which may clear it. Once recovery jobs are removed, queued downloads resume.

When a recovery job is removed, the bridge deletes its directly staged audio files from its shared import folder if its ownership marker is present and no other active, completed or recoverable job uses the folder. It does not follow symlinks or delete other non-audio files. If cleanup is unsafe or fails, removal fails; if another job uses the folder or ownership is unknown, the audio is retained. Jobs staged before ownership tracking was introduced need manual cleanup. Before re-grabbing, remove any remaining audio from the logged import folder; the bridge refuses another strict download while audio remains there. Review any partially imported library files in Lidarr as well. Then search and grab the album again; normal quota rules apply. Lidarr-native “retry” of a known failed NZBGet history entry also starts a new quota attempt.

The indexer's strict importer downloads the full album before allowing Lidarr to replace existing tracks, requires every audio file to map exactly once to the selected release, and verifies that every selected track has a newly registered file after the command completes. This supports upgrades and edition changes, but **Lidarr may delete existing files before the new import finishes**. Its import is not transactional, so an interruption or partial import may require removing leftovers and downloading again. Avoid concurrent imports for the same album. The legacy downloader's manual import behavior is unchanged.

### Storage and retention

Indexer maintenance runs at startup and roughly hourly. `AUDIO_INDEXER_RETENTION_DAYS` defaults to 30; set it to `0` to disable age-based job, handoff and abandoned-staging cleanup. Once that period has elapsed, removed jobs with no pending cleanup, their eligible old quota attempts, unused release handoffs and empty history directories are removed. A handoff that has expired needs a new search. Active, retryable and recovery jobs, pending queue cleanup, unresolved quota reservations and current-day quota charges are retained. Empty orphan history directories and abandoned temporary download files are removed only when safe; staging is retained while any job may require recovery. SQLite databases are compacted when at least 1 MiB of pages is unused.

Metadata cache and legacy marker expiry use their existing `AUDIO_CACHE_MAX_AGE_DAYS_*` and `AUDIO_RETRY_*_DAYS` settings, independently of indexer retention. Indexer mode runs those cleaners but no longer creates legacy downloaded/failed markers. Legacy `results.md` remains append-only and is not automatically trimmed. Older anonymous quota temporary files cannot be safely identified and must be reviewed manually; newly created quota temporary files use a distinctive prefix and are cleaned after retention.

### New Indexer settings

- `SERVICE_INDEXER_ENABLED` (default: `false`)
- `SERVICE_DEEMIXDOWNLOADER_ENABLED` (default: `true`; legacy wanted-list poller, must be disabled when using the indexer)
- `AUDIO_INDEXER_API_KEY` (required; minimum 32 characters)
- `AUDIO_INDEXER_API_KEY_FILE` (alternative to `AUDIO_INDEXER_API_KEY`)
- `AUDIO_INDEXER_PUBLIC_URL` (required; reachable from Lidarr, no URL path/query/fragment)
- `AUDIO_INDEXER_BIND` (default: `0.0.0.0`)
- `AUDIO_INDEXER_PORT` (default: `9797`)
- `AUDIO_INDEXER_RETENTION_DAYS` (default: `30`; `0` disables age-based job, handoff and abandoned-staging cleanup)
- `AUDIO_INDEXER_AUTO_RETRY_SEARCHES` (default: `false`; may automatically grab releases and bypass delay profiles)
- `AUDIO_INDEXER_CLIENT_USERNAME` (default: `lidarr-sidecar`)
- `AUDIO_INDEXER_CLIENT_PASSWORD` (required; minimum 16 characters)
- `AUDIO_INDEXER_CLIENT_PASSWORD_FILE` (alternative to `AUDIO_INDEXER_CLIENT_PASSWORD`)
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
- Data path (legacy downloaded/failed/not-found markers):
  - `/path/to/data:/data`
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
