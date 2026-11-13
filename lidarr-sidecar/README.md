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

Searches resolve artist/album text against Lidarr's local library and return each distinct MusicBrainz release/Deezer album pair that passes the matching gates. The indexer advertises raw text search to preserve artist names, punctuation and accents. For Lidarr installations still caching the old capabilities, it also recognizes Lidarr's cleaned search text, including an omitted leading "The"; ambiguous local matches are rejected. Text-only searches first check for a local artist name, then try artist/album word boundaries. A four-digit album title takes precedence over interpreting the same text as an artist and year. Artist-only searches return matched editions for that local artist. Searches do not consult the download quota, failure markers, or downloaded markers.

The sidecar warns when the resolved MusicBrainz artist has no active Deezer artist link, but does not require that link or use it for album discovery. Each offered album still requires a Deezer album link on its MusicBrainz release and must pass the matching gates. Missing release links are logged separately. MusicBrainz artist records without a Deezer link are cached for up to seven days, so a newly added link may not immediately clear the warning; metadata lookup failures are reported separately from missing links.

Report titles show the edition, track count, Deezer ID and local Lidarr release ID; a Deezer year is included when it differs from the album year. The full MusicBrainz release ID remains bound to the opaque handoff and forced import, so changing a later match does not alter an already queued job.

Redirect, UPC, lyric-type, title and track-count gates still apply. A positive Deezer track count is required for downloads and for indexer results. Title matching recognizes the dotted `D.L.X.` abbreviation for deluxe without bypassing the other gates. The configured instrumental exclusion retains its existing fallback when no non-instrumental release is available. Official status, commentary and other ranking preferences no longer hide other eligible editions from the indexer. Within the same release status, `AUDIO_DEPRIORITIZE_COMMENTARY_RELEASES` places recognized commentary and radio release specials after ordinary releases. This order is only a tie-breaker: Lidarr's quality, custom formats and other decision criteria take precedence. Configure Lidarr's custom formats if a particular edition must be preferred or rejected. The legacy wanted-list poller continues to select its single preferred match.

Newznab report titles omit album-title brackets and include the Lidarr album's year when available, so Lidarr can distinguish titles such as an original album and a parenthesized re-recording. Before offering a result, including a cached result, the sidecar checks Lidarr's parse API for the intended artist and album IDs and rejects conflicting album titles; omissions are logged as warnings. No bitrate or quality is advertised because the final format is unknown; a title that Lidarr interprets as a specific quality is omitted. The reported `0 B` size and current publication age are placeholders, not actual download size or release age. These conservative checks may omit valid matches. Lidarr's final grab decisions are not returned to the indexer, so the sidecar cannot log every reason Lidarr declines a report.

Lidarr's Newznab indexer configuration must have RSS disabled, while interactive and automatic search are enabled. Album-specific searches are supported; a generic RSS poll has no album identity and returns no releases.

### Verified behavior and limitations

The integration was exercised against isolated Lidarr 3.1.6.5079 instances using fake Deezer metadata and, for the synthetic import test, generated silent MP3s. Interactive search and grab, automatic `AlbumSearch`, NZBGet `append`/`listgroups`/`history`, a forced import of all 12 Let It Be tracks with the selected artist/album/release IDs, and a failed-job `HistoryRedownload` retry were verified. Lidarr's automatic search command requires `albumIds: [<id>]`; sending a singular `albumId` fails. Real isolated download tests are described below.

Lidarr supplies a `drone` download ID with NZBGet `append`; the bridge persists and echoes it in `listgroups` and `history` so Lidarr can correlate the client item. Live validation confirmed a quota-waiting item appears in both the NZBGet-compatible queue and Lidarr's `/api/v1/queue`, with the same download ID and a “waiting for daily download quota” title. Other Lidarr versions have not been tested.

After a successful forced import, the bridge removes the matching Lidarr queue item(s) by download ID without blocklisting them. Cleanup requests are persisted and retried after failures or restarts, including for duplicate grabs. An ID not yet visible in Lidarr remains pending; if it was independently removed, cleanup may continue checking for it. Its NZBGet `HistoryDelete` handler only updates bridge state; it does not delete imported media. A unique, empty history destination is also kept available so Lidarr never scans the shared staging root.

Searches run one at a time in a persistent, deduplicated background queue, so a slow search can delay later searches. The indexer waits up to 10 seconds for a result; if it is still running, it returns a 503 with a warming message rather than reporting an incomplete search as no matches. Lidarr may temporarily disable the indexer after a 503, so subsequent searches during that backoff may never reach the sidecar's background queue. Once the sidecar logs the search as completed and Lidarr's backoff has expired, retry it manually in Lidarr; the bridge does not trigger a new search or grab automatically. Searches that never reached the sidecar must also be retried. Completed search responses are reused for five minutes or until restart. Pending work resumes after a sidecar restart.

Lidarr 3.1.6 marks search commands submitted through its API as user-invoked. Reissuing an automatically initiated search this way can bypass Lidarr delay profiles, so simply observing and replaying commands would not preserve the original behavior. A safe automatic retry mechanism has not yet been implemented.

Release-group metadata is fetched in pages of up to 100 releases and cached per page. Complete existing release-cache entries are reused; a release missing from the browse response is fetched individually. Every eligible linked edition is checked, so large artists or release groups can remain warming for some time. Newznab responses support `offset` and `limit` pagination (up to 100 per page); Lidarr 3.1.6 limits an individual indexer query to 1,000 reports.

MusicBrainz requests are serialized within the sidecar process and honor numeric or HTTP-date `Retry-After` values. Background searches retry transient failures indefinitely using exponential backoff with jitter (base delay capped at 60 seconds). A prolonged outage can keep a search warming indefinitely; previously cached pages remain available. This rate limit is process-local; separate sidecar processes do not coordinate with one another.

Transient Deezer failures also leave a background search pending for retry rather than caching partial results. Deezer album cache entries expire according to `AUDIO_CACHE_MAX_AGE_DAYS_DEEZER`; permanent API errors and invalid links can still exclude results.

An isolated Lidarr 3.1.6 clone sent the raw `The Struts Pretty Vicious` query, and both that query and the cached-capabilities form `Struts Pretty Vicious` resolved to the intended local album using a fake indexer. A search-only check on the separate test stack reached MusicBrainz and Deezer for `Pretty Vicious`, but returned no results because the linked release lacked a MusicBrainz barcode and the default UPC gate rejected it. No grab or download was submitted.

On 2026-11-13, an isolated Taylor Swift artist search initially returned the warming response, then completed in about 93 seconds despite repeated MusicBrainz 503s. A search-only retry returned 16 results. A subsequent manual search through Lidarr for `The Life of a Showgirl` returned one result using the cached metadata. Neither check grabbed or downloaded anything.

After correcting report titles, an isolated interactive artist search returned 16 results with 16 distinct intended album IDs. Lidarr accepted the five previously misidentified albums and rejected the other 11 because matching releases were already queued. This was search-only: no new grabs or downloads were submitted.

An isolated interactive search for Taylor Swift's `1989` returned two editions: the 13-track album and a 26-track radio special. Both mapped to the intended Lidarr album with unknown quality, and their synthetic NZBs retained distinct MusicBrainz release and Deezer album identities. Both were marked as already queued by Lidarr; job states were unchanged. To repeat a search-only check, open the album in the isolated Lidarr, choose Interactive Search, and compare the edition details without clicking a download button. Results depend on metadata and configured gates.

After recognizing `D.L.X.` as deluxe, the same search returned a third result: a 19-track deluxe release whose MusicBrainz and Deezer track counts and UPC agree. In a separate network-isolated Lidarr clone, a fake bridge with no download worker offered all three editions and automatic album search queued the deluxe edition rather than the radio special. In another offline clone, forced manual import of 13 generated silent tracks switched the monitored release from the 55-track edition to the selected 13-track release and registered every selected track. This did not test a real multi-edition download.

On 2026-11-13, an isolated Lidarr 3.1.6.5079 manual search for Olivia Rodrigo's `SOUR` returned one result from the configured Newznab indexer in under one second using cached metadata. The Lidarr queue remained empty and the test import directory had no files. This verified search delivery only; it did not grab or download anything, and no Deezer token was used.

A later user-triggered isolated grab downloaded Olivia Rodrigo's `SOUR` and Lidarr imported 11 tracks. Logs exposed that Lidarr kept the item in `importPending` because the bridge's reported history destination did not exist. The stale queue entry was removed manually after confirming the tracks remained in the isolated library; the later test below verified automatic cleanup.

On 2026-11-13, a fresh isolated Lidarr clone and the `1f1c218` sidecar image searched and grabbed the 12-track `GUTS` edition with Deezer album ID `484437855` and Lidarr release ID `94`. The forced `ManualImport` command retained artist ID `1`, album ID `2`, and release ID `94`; Lidarr registered all 12 selected tracks with distinct files. The daily quota recorded one completed download, and the bridge automatically removed the item from Lidarr's queue. No `DownloadedAlbumsScan` command was observed during this import. This used real credentials and audio with the user's authorization, in separate test directories; it did not test a real edition replacement.

In a network-isolated Lidarr 3.1.6 clone, deferred auto-configuration created and then updated a dedicated NZBGet client and bound Newznab indexer successfully. A synthetic search and grab stayed in the queue while forced import was held; after importing 14 generated silent tracks into the selected release, the matching Lidarr queue item was removed. Another test replaced a 13-track edition with a 19-track edition and verified that all selected tracks received new registered files. A simulated uncertain download was removed through Lidarr's queue and its quota reservation charged. These checks used no Deezer credentials or real downloads.

Some matching editions are radio specials; review the selected edition or configure Lidarr's preferences before grabbing.

### Setup and migration

1. Stop the old wanted-list poller before enabling the indexer. Set `SERVICE_DEEMIXDOWNLOADER_ENABLED=false` and `SERVICE_INDEXER_ENABLED=true`; the legacy poller defaults to `true` and the indexer to `false`. Both services refuse to run together because the legacy `daily_download_state` writer does not coordinate with the new quota database.
2. Set `AUDIO_INDEXER_API_KEY` to a random secret of at least 32 characters and `AUDIO_INDEXER_CLIENT_PASSWORD` to a separate random secret of at least 16 characters. For example, generate values with `openssl rand -hex 32` and `openssl rand -hex 24`. Set `AUDIO_INDEXER_PUBLIC_URL` to the HTTP(S) URL reachable from Lidarr, with no path, query, or fragment. Set `SERVICE_INDEXER_ENABLED=true`.
3. Keep the Lidarr config XML mounted read-only and provide an ARL token file as for the existing downloader. Mount `AUDIO_WORK_PATH` persistently. Mount `AUDIO_SHARED_LIDARR_PATH` at the same path in both containers; the sidecar stages and tags files there before forced manual import.
4. Either set `AUTOCONFIG_DEEMIX_INDEXER=true` to idempotently create/update the dedicated download client and Newznab indexer on startup, or add them manually. Auto-configuration runs after the bridge starts listening and before its download worker starts. It uses the names in `AUDIO_INDEXER_CLIENT_NAME` and `AUDIO_INDEXER_NAME`; a configuration failure stops the indexer service and marks the container unhealthy.
5. Add a **Download Client / NZBGet** pointing at `AUDIO_INDEXER_CLIENT_HOST` and port (`AUDIO_INDEXER_CLIENT_PORT`, defaulting to `AUDIO_INDEXER_PORT`, which defaults to `9797`), with `AUDIO_INDEXER_CLIENT_USERNAME` and `AUDIO_INDEXER_CLIENT_PASSWORD`. Set the music category to `Music` and leave “Add Paused” disabled. The NZBGet version/schema handshake was verified against Lidarr 3.1.6.5079.
6. Add an **Indexer / Newznab** with the public URL, API path `/api`, and `AUDIO_INDEXER_API_KEY`. Select audio categories (3000, 3010, 3030, 3040). Enable interactive and automatic search; disable RSS; set its `downloadClientId` to the NZBGet client created above. This binding prevents synthetic NZBs from being sent to a normal Usenet client.
7. Ensure the indexer URL and NZBGet client address are reachable from Lidarr over a private network. The bridge uses HTTP; do not expose it directly to the Internet. Use a trusted network or a TLS-terminating reverse proxy, and preserve the configured public URL when using a proxy.
8. Test the indexer and client in Lidarr before enabling automatic searches. Do not configure this indexer to use an ordinary Usenet client: its synthetic NZBs are only meaningful to the sidecar bridge.

The bridge keeps a grab queued while it downloads and runs Lidarr's forced Manual Import API with the chosen artist, album, and release IDs. It only reports success after that command completes and Lidarr registers track files, preventing the download client's normal completed-download scan from racing the forced import. The client history uses a unique, empty output path after manual import so it cannot rescan the shared staging root.

`AUDIO_DAILY_DOWNLOAD_LIMIT=0` is unlimited. Otherwise, each distinct album download reserves one slot immediately before download, releases it only when download failure is known, and records completion before import; an import failure therefore still counts. The local calendar day uses the container timezone (`TZ`). When full, searches still return matches and grabs remain in the NZBGet-compatible queue with a “waiting for daily download quota” title; the worker retries after the next local midnight. Pending reservations survive midnight and restart. Quota state lives under `AUDIO_WORK_PATH` in `daily_download_quota.sqlite3`.

On startup and when used, the quota reconciles the legacy `daily_download_state` count and mirrors completed downloads back to that file. Stop one service before switching modes; they do not coordinate concurrent writes. The updated legacy poller refuses to start while indexer reservations remain unresolved. Before rolling back to an older image, stop the indexer and resolve or conservatively remove all uncertain jobs first: older pollers cannot check reservations. Older pollers also do not record downloads while their limit is unlimited, so avoid switching back from an older image that downloaded with `AUDIO_DAILY_DOWNLOAD_LIMIT=0` until the next local day. Corrupt/missing initialized quota state fails closed; do not delete the lock or database to reset the limit. The priority file is not read or modified by the new flow; Lidarr-grabbed jobs all use the same quota. Legacy `AUDIO_PRIORITY_*` settings apply only if the old poller is explicitly re-enabled.

Queued and quota-waiting jobs may be removed; removal is refused while downloading or importing because the bridge cannot safely cancel the operation. Interrupted or uncertain downloads and unsuccessful imports appear in the queue as “needs manual recovery” and are not automatically retried. To retry, remove the item in Lidarr with **Remove from Download Client** enabled and blocklisting disabled. The bridge conservatively charges any unresolved reservation to the removal day before clearing the item; an already completed download is not charged twice. With a limit of one, the retry may therefore wait until the next local day. If quota state is unavailable, removal fails rather than releasing an uncertain reservation. Do not edit or delete the quota database.

Before re-grabbing, remove leftover audio for that attempt from its shared import folder; an unsuccessful import logs its path. The bridge does not delete these files when removing a queue item and refuses to start another strict download while audio remains in that folder. Review any partially imported library files in Lidarr as well. Then search and grab the album again; normal quota rules apply. Lidarr-native “retry” of a known failed NZBGet history entry also starts a new quota attempt.

The indexer's strict importer downloads the full album before allowing Lidarr to replace existing tracks, requires every audio file to map exactly once to the selected release, and verifies that every selected track has a newly registered file after the command completes. This supports upgrades and edition changes, but **Lidarr may delete existing files before the new import finishes**. Its import is not transactional, so an interruption or partial import may require removing leftovers and downloading again. Avoid concurrent imports for the same album. The legacy downloader's manual import behavior is unchanged.

### New Indexer settings

- `SERVICE_INDEXER_ENABLED` (default: `false`)
- `SERVICE_DEEMIXDOWNLOADER_ENABLED` (default: `true`; legacy wanted-list poller, must be disabled when using the indexer)
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
