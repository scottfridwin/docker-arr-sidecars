# Lidarr indexer development context

This is implementation and historical validation context for maintainers and coding agents, not a setup guide.
See the [Lidarr sidecar README](../lidarr-sidecar/README.md) for configuration, search behavior and recovery.
The earlier implementation plan and additional history are in
[DEEMIX_INDEXER_PLAN.txt](../lidarr-sidecar/DEEMIX_INDEXER_PLAN.txt).

## Search and protocol considerations

- The bridge advertises raw Newznab text searches, but also accepts older cleaned Lidarr queries. Text-only
  resolution checks local artist names and artist/album boundaries; a four-digit album title takes precedence over
  treating the final token as a year. Ambiguous matches are not offered.
- Each eligible MusicBrainz release/Deezer album pair retains its release identity through the synthetic NZB and
  forced import. The bridge checks report titles through Lidarr's parse API against the intended artist and album,
  including cached results, and omits titles that conflict or imply a specific quality.
- Release-group browse responses are paged and cached. The bridge checks every eligible linked edition, reuses
  complete release caches and fetches releases individually when absent from the browse response. Newznab responses
  support offset/limit pagination; Lidarr 3.1.6 limits an indexer query to 1,000 reports.
- MusicBrainz requests share a process-local interval and retry schedule. Retries honor numeric and HTTP-date
  `Retry-After`; background work retries transient failures indefinitely with exponential backoff and jitter.
  Two search workers allow other searches to proceed when one is slow, but both can remain occupied during an
  extended outage. Separate sidecar processes do not coordinate the rate limit.
- Lidarr 3.1.6 marks search commands sent through its API as user-invoked. The optional automatic retry mechanism
  can therefore bypass delay profiles and can turn an interactive search into an automatic grab; it is disabled
  by default. Dispatch outcomes that cannot be confirmed are not retried automatically.
- Lidarr supplies a `drone` download ID when appending an NZBGet item. The bridge persists it for queue/history
  correlation and retries queue removal after successful forced import. History points to an empty per-job directory
  to avoid rescanning the staging root.

## Historical validation

The following checks were performed against isolated Lidarr 3.1.6.5079 instances, primarily on 2026-11-13.
They describe the versions tested at the time, not guarantees for later changes or other Lidarr versions.

- Synthetic tests covered interactive and automatic searches, grabs, the NZBGet queue/history and failed-job retry,
  forced import of generated silent tracks, quota waiting, and queue correlation. Auto-configuration created and
  updated a bound client and indexer. An isolated edition replacement verified all selected tracks were registered,
  and an uncertain download removal charged its quota reservation.
- Search-only checks covered raw and cleaned artist/album text, cached single-album search, multi-album artist
  search, report-title identity, and multiple editions. One cold artist search took about 93 seconds with repeated
  MusicBrainz 503s; another album was rejected because its MusicBrainz barcode was missing under the default UPC gate.
- An authorized real isolated download imported an album, but exposed a stale `importPending` queue entry caused by
  a missing history destination. The entry was manually removed. A later real isolated download using commit
  `1f1c218` registered all 12 selected tracks, charged one quota slot and automatically removed the queue item.
  A real edition replacement was not tested.

Lidarr's automatic `AlbumSearch` API command uses `albumIds: [<id>]`, not a singular `albumId`. Consult the tests
and current implementation before relying on historical observations.

The current retry path has been tested with a simulated Lidarr search and grab, including quota exhaustion and a
simulated day reset. An isolated Lidarr 3.1.6.5079 instance also accepted the `AlbumSearch` command payload; the
complete retry-to-grab path has not been validated against a real Lidarr instance.
