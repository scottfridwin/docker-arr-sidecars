# Lidarr Music Video Sidecar

Downloads the official music videos of your Lidarr artists from YouTube into a music video library
(`<VIDEO_LIBRARY_PATH>/<Artist>/<Song>.mkv`, with `<Song>.nfo` and `<Song>-poster.jpg`, which Jellyfin, Kodi and Emby
read).

It is a separate image from the [Lidarr sidecar](../lidarr-sidecar/README.md) because it needs different tools
(yt-dlp, deno) and a different network: YouTube answers downloads from VPN and many datacenter addresses with "Sign in
to confirm you're not a bot", so it must not share a VPN container's network the way a Deezer downloader often does.
It only reads from Lidarr and changes no Lidarr settings.

## Container Image

- Package: <https://github.com/scottfridwin/docker-arr-sidecars/pkgs/container/lidarr-musicvideo-sidecar>
- Pull: `docker pull ghcr.io/scottfridwin/lidarr-musicvideo-sidecar:latest`

## Services

- MusicVideoDownloader (`services/persistent/MusicVideoDownloader.py`)
  - Finds the official YouTube channels of your Lidarr artists in MusicBrainz, picks the music videos from their
    uploads and downloads them with yt-dlp

## How it works

Each run (`VIDEO_INTERVAL`, default daily):

1. Takes the monitored Lidarr artists, or only those with the Lidarr tag `VIDEO_ARTIST_TAG` when it is set, that were
   not checked in the last `VIDEO_ARTIST_RECHECK_DAYS`.
2. Looks up each artist's official YouTube channels in their MusicBrainz URL relationships (`youtube` links, often the
   artist channel and the VEVO channel). Artists without one are skipped; add the link in MusicBrainz to include them.
3. Lists the channels' uploads with yt-dlp and keeps the music videos (below), one per song.
4. Downloads those not already in the artist's folder, at most `VIDEO_MAX_DOWNLOADS_PER_RUN` per run; the rest follow
   on the next runs. Videos already in the folder are recognised by song title (files you added yourself count) or
   by the YouTube ID in their NFO.

Downloads land in `VIDEO_WORK_DIR` and are copied into the library under a hidden `.partial` name, then renamed, so
library watchers (Jellyfin, Tdarr) never pick up a half-copied file. The file is the best YouTube stream (often AV1 or
VP9) in MKV; convert it afterwards if your players need another codec. State (checked artists, downloaded and failed
videos) is kept in `VIDEO_STATE_DIR/state.json`; a failed download is retried on later checks until
`VIDEO_DOWNLOAD_ATTEMPT_THRESHOLD`.

## Which uploads are music videos

YouTube has no "official music video" flag, so the title decides. An upload is kept when it:

- is marked as a music video ("Official Music Video", "Official Video", "(Music Video)"), or credits a featured
  artist ("Song (feat. X)"), or is a plain "`<Artist> - <Song>`" upload on a VEVO channel (VEVO only carries label
  uploads), and
- has none of the `VIDEO_EXCLUDE_KEYWORDS` anywhere in the title (lyric video, visualizer, official audio, behind the
  scenes, trailer, interview, acoustic, ...), and
- has none of the `VIDEO_EXCLUDE_QUALIFIERS` as a whole word in a bracket group or a trailing "` - ...`" / "` | ...`"
  part of the title (live, audio, cover, episode, session, playback, tour, ...), and
- lasts between `VIDEO_MIN_DURATION` and `VIDEO_MAX_DURATION` seconds.

When a song has several uploads, "Official Music Video" beats "Official Video" beats a plain title, VEVO beats the
artist channel, and then the most viewed wins. The file name is the song title without the upload tags
("Californication (Official Music Video) [HD UPGRADE]" becomes `Californication.mkv`).

Checked against hand-picked libraries of three artists (Red Hot Chili Peppers, The Struts, The Lonely Island), this
found 58 of their 64 music videos and proposed 21 more: 17 official music videos they were missing, 2 cover songs
and 2 promo clips. It misses music videos titled with only the song name on a non-VEVO channel. Try
`VIDEO_DRY_RUN=true` first: it writes the videos it would download to `VIDEO_STATE_DIR/dry-run-<time>.md` and
changes nothing.

IMVDb was evaluated as the source of "official" videos and not used: its search API rejects every request (HTTP 403)
and it lists only a fraction of most artists' videos.

## Example

```yaml
lidarr-musicvideo-sidecar:
  image: ghcr.io/scottfridwin/lidarr-musicvideo-sidecar:latest
  user: "1000:1000"            # needs write access to the music video library
  read_only: true
  cap_drop: [ALL]
  security_opt: ["no-new-privileges:true"]
  pids_limit: 64               # yt-dlp, deno and ffmpeg run together
  mem_limit: 512m
  tmpfs: ["/tmp"]
  environment:
    - ARR_HOST=lidarr
    - VIDEO_ARTIST_TAG=musicvideos
  volumes:
    - /path/to/lidarr/config.xml:/lidarr/config.xml:ro
    - /path/to/music-videos:/music-videos
    - /path/to/data:/data
    - /path/to/work:/work
```

## Required Mounts

- Lidarr config XML (for the API key): `/path/to/lidarr/config.xml:/lidarr/config.xml:ro`
- Music video library: `/path/to/music-videos:/music-videos`
- State (`state.json`, MusicBrainz cache, dry-run reports): `/path/to/data:/data`
- Downloads in progress: `/path/to/work:/work`

## Environment Variables

General:

- `ARR_CONFIG_PATH` (default: `/lidarr/config.xml`)
- `ARR_HOST` (default: `lidarr`)
- `LOG_LEVEL` (default: `INFO`)
- `UMASK` (default: `0002`)

MusicVideoDownloader:

- `VIDEO_LIBRARY_PATH` (default: `/music-videos`; videos go to `<Artist>/<Song>.mkv`)
- `VIDEO_STATE_DIR` (default: `/data`)
- `VIDEO_WORK_DIR` (default: `/work`)
- `VIDEO_INTERVAL` (default: `24h`; `none` runs once)
- `VIDEO_ARTIST_TAG` (default: empty = every monitored artist; otherwise only artists with this Lidarr tag)
- `VIDEO_ARTIST_RECHECK_DAYS` (default: `7`)
- `VIDEO_MAX_DOWNLOADS_PER_RUN` (default: `10`)
- `VIDEO_DOWNLOAD_ATTEMPT_THRESHOLD` (default: `3`)
- `VIDEO_DOWNLOAD_DELAY` (default: `30` seconds between downloads)
- `VIDEO_MIN_DURATION` / `VIDEO_MAX_DURATION` (default: `90` / `900` seconds)
- `VIDEO_EXCLUDE_KEYWORDS` / `VIDEO_EXCLUDE_QUALIFIERS` (comma-separated; defaults in
  `python/music_video_downloader/config.py`)
- `VIDEO_FORMAT` (default: `bv*+ba/b`, yt-dlp format selector; the container is always MKV)
- `VIDEO_COOKIES_FILE` (optional, YouTube cookies in Netscape format, if downloads hit the bot check anyway)
- `VIDEO_DRY_RUN` (default: `false`)

## Notes

- yt-dlp runs YouTube's player JavaScript with the bundled deno; `DENO_DIR` and `XDG_CACHE_HOME` point at `/tmp`, so
  mount a writable `/tmp` (tmpfs) with a read-only root filesystem.
- With every monitored artist selected, the first runs take a while: MusicBrainz allows one request per second and
  each channel listing takes a few seconds. A Lidarr tag keeps the selection small.
- yt-dlp needs regular updates to keep up with YouTube; Renovate updates the pins in `requirements.txt`.
