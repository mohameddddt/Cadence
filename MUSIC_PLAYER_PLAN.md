# Music Player App — Master Plan

A personal mobile music player that:

- Plays **local files** already on the device
- **Downloads** audio from YouTube, SoundCloud, Internet Archive, Bandcamp (and more) through **yt-dlp**
- Auto-tags tracks using **MusicBrainz** (+ AcoustID fingerprinting)
- Fetches album art from the **Cover Art Archive**
- Shows **lyrics** (synced when possible)
- Adds extras: scrobbling, artist info, radio, smart playlists, etc.

This document is a roadmap. There is no code in it. Work through the phases in order. Each phase ends with something you can run and use.

---

## Table of Contents

1. [Legal & Distribution Reality Check](#1-legal--distribution-reality-check)
2. [Choosing the Tech Stack](#2-choosing-the-tech-stack)
3. [High-Level Architecture](#3-high-level-architecture)
4. [Data Model](#4-data-model)
5. [Phase 0 — Project Setup](#phase-0--project-setup)
6. [Phase 1 — Local Playback Core](#phase-1--local-playback-core)
7. [Phase 2 — Library Scanning & Database](#phase-2--library-scanning--database)
8. [Phase 3 — yt-dlp Downloader](#phase-3--yt-dlp-downloader)
9. [Phase 4 — Metadata: MusicBrainz + AcoustID](#phase-4--metadata-musicbrainz--acoustid)
10. [Phase 5 — Cover Art](#phase-5--cover-art)
11. [Phase 6 — Lyrics](#phase-6--lyrics)
12. [Phase 7 — Extra Sources & Integrations](#phase-7--extra-sources--integrations)
13. [Phase 8 — UI/UX](#phase-8--uiux)
14. [Phase 9 — Settings, Background Work, Storage](#phase-9--settings-background-work-storage)
15. [Phase 10 — Testing](#phase-10--testing)
16. [Phase 11 — Build & Release](#phase-11--build--release)
17. [API & Service Reference](#api--service-reference)
18. [Common Pitfalls](#common-pitfalls)
19. [Milestone Checklist](#milestone-checklist)
20. [Future Ideas](#future-ideas)

---

## 1. Legal & Distribution Reality Check

Read this before you start. These points affect your architecture.

| Topic | What it means for you |
|---|---|
| **YouTube ToS** | Downloading from YouTube breaks YouTube's Terms of Service. **Google Play will reject or remove** apps that do it. Plan to distribute through **GitHub Releases** and/or **F-Droid** (F-Droid will mark it with the "NonFreeNet" anti-feature), or keep it for personal use only. |
| **iOS** | The App Store will not accept it, and iOS can't run yt-dlp (a Python program that spawns ffmpeg) on the device. For iOS you need a **self-hosted backend** plus sideloading (AltStore, or Xcode with a free or paid dev account). |
| **Bandcamp** | Download only free or name-your-price releases, or things you **bought** (use your purchase links for full quality). yt-dlp only gets the 128 kbps stream MP3. |
| **SoundCloud** | Many tracks are stream-only. Respect the artist's settings. Go+ tracks are DRM-protected and won't work. |
| **Internet Archive** | Mostly public domain or Creative Commons (e.g. the Live Music Archive), so it's legally the safest source. |
| **Genius lyrics** | The official Genius API **does not return lyrics text**, only metadata and a page URL. Scraping the text breaks their ToS, and lyrics are copyrighted. Use Genius for **song info and annotations links**, and use **LRCLIB** (an open database) for lyrics text. See Phase 6. |
| **MusicBrainz** | Free, but you **must** send a descriptive `User-Agent` and stay at **≤ 1 request/second**. |

**Recommendation:** build it as a personal, open-source app. Keep "sources" pluggable so each one can be turned on or off in Settings.

---

## 2. Choosing the Tech Stack

### The main constraint: running yt-dlp

yt-dlp is Python and needs **ffmpeg** for audio extraction, conversion, and embedding thumbnails. On mobile you have two options:

| Approach | How | Pros | Cons |
|---|---|---|---|
| **A. On-device (Android only)** | Use the [`youtubedl-android`](https://github.com/yausername/youtubedl-android) library, which bundles Python + yt-dlp + ffmpeg as native libs | Works offline from any server; no infrastructure | Android only; APK gets bigger (~30–60 MB per ABI); yt-dlp updates must be done in-app |
| **B. Companion server** | Small self-hosted server (Python FastAPI/Flask + yt-dlp + ffmpeg in Docker) on a home PC, Raspberry Pi, or VPS. The app sends a URL and downloads the finished file | Works on **iOS and Android**; easy yt-dlp updates; heavy work is off the phone | You must host and secure a server; needs network access (Tailscale or a VPN is ideal) |
| **C. Hybrid** | On-device on Android, server on iOS, behind one "Downloader" interface | Best of both | Most work |

### Recommended stacks

**Option 1: Android-first, native (recommended if you mostly use Android)**
- Language: **Kotlin**
- UI: **Jetpack Compose** + Material 3
- Playback: **AndroidX Media3** (ExoPlayer + MediaSessionService). This gives you the notification, lock screen, Bluetooth, Android Auto, and Wear controls
- Database: **Room** (SQLite)
- Networking: **Retrofit/Ktor + OkHttp**, **kotlinx.serialization**
- Images: **Coil**
- Background work: **WorkManager**
- DI: **Hilt** or **Koin**
- Tag writing: **jaudiotagger** (or TagLib through JNI)
- Downloader: **youtubedl-android** (yt-dlp + ffmpeg + aria2c)
- Fingerprinting: **Chromaprint** (`fpcalc`) compiled for Android, or use the fingerprinting built into the server

**Option 2: Cross-platform (if you want iOS as well)**
- **Flutter** (Dart)
- Playback: `just_audio` + `audio_service` (background and media controls)
- Database: `drift` or `isar`
- Networking: `dio`
- Tags: `metadata_god` / `audiotags` (Rust-based) or tag on the server
- Downloader: companion server (approach B). On Android you can also call youtubedl-android through a platform channel

> Pick **one** before you start. The rest of this plan applies to both stacks. Library names are given for the Kotlin stack, with Flutter equivalents in parentheses where they matter.

---

## 3. High-Level Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                          UI Layer                            │
│  Library · Now Playing · Search/Download · Lyrics · Settings │
└───────────────▲──────────────────────────────▲───────────────┘
                │ state (ViewModels / Bloc)    │
┌───────────────┴──────────────────────────────┴───────────────┐
│                       Domain / Use-cases                     │
│ PlayQueue · ScanLibrary · DownloadTrack · IdentifyTrack      │
│ FetchCover · FetchLyrics · Scrobble · BuildSmartPlaylist     │
└──────▲──────────────▲──────────────▲──────────────▲──────────┘
       │              │              │              │
┌──────┴─────┐ ┌──────┴──────┐ ┌─────┴──────┐ ┌─────┴───────────┐
│ Playback   │ │ Library DB  │ │ Downloader │ │ Metadata        │
│ Service    │ │ (Room)      │ │ Engine     │ │ Providers       │
│ (Media3)   │ │ + FileScan  │ │ (yt-dlp)   │ │ MB · AcoustID   │
│            │ │ + TagIO     │ │ local/srv  │ │ CAA · LRCLIB    │
└────────────┘ └─────────────┘ └────────────┘ │ Genius · Last.fm│
                                              └─────────────────┘
```

### Key design rules
1. **Provider interfaces.** Every external service sits behind an interface (`SourceProvider`, `MetadataProvider`, `CoverProvider`, `LyricsProvider`). You can then add, remove, or reorder sources without touching the UI.
2. **Offline-first.** The database is the single source of truth. Network results are cached in the DB and on disk.
3. **Background everything.** Scanning, downloading, tagging, and fetching covers or lyrics all run in WorkManager jobs that survive the app being killed.
4. **Rate limiting in one place.** A shared per-host rate limiter (MusicBrainz 1 req/s, AcoustID 3 req/s, etc.).
5. **Write tags into files.** Metadata goes into the audio file as ID3/Vorbis/MP4 tags, not only into the DB. Your library then works in other players too.

---

## 4. Data Model

Core tables (simplified):

| Table | Key fields |
|---|---|
| **Track** | id, filePath/contentUri, title, artistId, albumId, trackNo, discNo, durationMs, year, genre, bitrate, format, sizeBytes, dateAdded, lastPlayed, playCount, rating, source (LOCAL/YOUTUBE/SOUNDCLOUD/IA/BANDCAMP/…), sourceUrl, **mbRecordingId**, **mbReleaseId**, **acoustId**, replayGainTrack, lyricsId, hash |
| **Artist** | id, name, sortName, **mbArtistId**, imagePath, bio |
| **Album** | id, title, artistId, year, **mbReleaseId**, **mbReleaseGroupId**, coverPath, coverSource |
| **Playlist** / **PlaylistTrack** | id, name, isSmart, smartRules(JSON) / playlistId, trackId, position |
| **Lyrics** | id, trackId, plainText, syncedLrc, source, fetchedAt |
| **DownloadJob** | id, url, sourceType, status (QUEUED/RUNNING/POSTPROCESSING/DONE/FAILED), progress, outputPath, error, createdAt, options(JSON) |
| **ScrobbleQueue** | trackId, timestamp, submitted |
| **ApiCache** | key (url+params hash), response, expiresAt |

Add indexes on `mbRecordingId`, `sourceUrl`, and `filePath` so you can detect duplicates.

---

## Phase 0 — Project Setup

1. Install the tools: Android Studio (or Flutter SDK + Android Studio/Xcode), JDK 17, Git.
2. Create the repo and pick a license (GPL-3.0 fits, since yt-dlp is Unlicense and ffmpeg builds are often GPL).
3. Set up the module/folder layout: `app`, `core-playback`, `core-db`, `core-network`, `feature-library`, `feature-downloader`, `feature-metadata`, `feature-lyrics`.
4. Add CI (GitHub Actions) that builds the APK and runs tests on every push.
5. Register for API keys (all free):
   - **AcoustID** application key: acoustid.org/new-application
   - **Genius** client access token: genius.com/api-clients
   - **Last.fm** API key: last.fm/api/account/create
   - **ListenBrainz** user token (from your profile)
   - Optional: **Discogs** token, **fanart.tv** key, **Jamendo** client id
6. Store keys in `local.properties` / `.env`. **Never commit them.**
7. Pick your app's `User-Agent`, e.g. `MyMusicPlayer/0.1 ( you@example.com )`. MusicBrainz requires this format.

**Deliverable:** an empty app that builds and runs, plus CI.

---

## Phase 1 — Local Playback Core

Goal: play a file reliably, including in the background.

1. **Playback service.** Create a `MediaSessionService` (Media3) that owns an ExoPlayer instance. (Flutter: `audio_service` + `just_audio`.)
2. **Media notification and lock screen controls.** Media3 provides these automatically through MediaSession.
3. **Audio focus.** Pause for calls and duck for navigation prompts. ExoPlayer does this when `handleAudioFocus = true`.
4. **Headphone unplug.** Pause on "becoming noisy".
5. **Queue.** Play next, add to queue, reorder, shuffle, and repeat (off/one/all). Save the queue and position to the DB so they survive restarts.
6. **Gapless playback.** ExoPlayer supports it when files have correct encoder delay/padding metadata.
7. **Crossfade (optional).** Needs two players or a custom audio processor. Leave it for later.
8. **ReplayGain / volume normalization.** Read the REPLAYGAIN tags and apply the gain. yt-dlp downloads can be analyzed with ffmpeg's `loudnorm`/`replaygain` filters.
9. **Equalizer.** Android `Equalizer` / `BassBoost` audio effects on the player's audio session id, or a system EQ intent.
10. **Sleep timer.** Stop after N minutes or at the end of the current track.
11. **Android Auto / Bluetooth.** Expose a `MediaLibraryService` browse tree (Albums/Artists/Playlists).

**Deliverable:** pick a file and play it with notification controls. Playback keeps going with the screen off.

---

## Phase 2 — Library Scanning & Database

1. **Permissions**
   - Android 13+: `READ_MEDIA_AUDIO`
   - Android ≤12: `READ_EXTERNAL_STORAGE`
   - Notifications: `POST_NOTIFICATIONS` (Android 13+)
2. **Scanning**
   - Quick path: query **MediaStore.Audio** for all audio files.
   - Also let the user pick extra folders through **Storage Access Framework** (`OpenDocumentTree`) and keep the persistent URI permission.
3. **Tag reading.** For each file, read title/artist/album/track#/year/genre/embedded art/MBIDs/lyrics tags (jaudiotagger or TagLib).
4. **Grouping.** Group albums by `(albumArtist, album)` so compilations don't split into one album per artist. Use MBIDs when available.
5. **Incremental rescans.** Store `lastModified` + size. Only re-read changed files. Remove entries whose files are gone.
6. **Watching for changes.** Re-scan on app start and through a `ContentObserver` on MediaStore.
7. **Embedded art.** Extract it to a cache folder and save the path on the Album row.
8. **Search.** Use SQLite **FTS4/FTS5** over title/artist/album for fast search-as-you-type.

**Deliverable:** a Library screen with Songs / Albums / Artists / Folders tabs, filled in from the device.

---

## Phase 3 — yt-dlp Downloader

### 3.1 Engine setup

**On-device (Android, youtubedl-android):**
1. Add the `library`, `ffmpeg`, and (optionally) `aria2c` modules.
2. Initialize them in `Application.onCreate()`.
3. Add a "Update yt-dlp" action (the library can self-update to the latest stable or nightly). **YouTube breaks old versions often, so update weekly or automatically.**
4. Use ABI splits (`arm64-v8a`, `armeabi-v7a`, `x86_64`) to keep the APK size down.

**Server (for iOS / hybrid):**
1. Docker image: `python:3.12-slim` + `ffmpeg` + `yt-dlp` + `chromaprint` (fpcalc).
2. Endpoints (conceptual):
   - `POST /jobs` with a url and options, returns a jobId
   - `GET /jobs/{id}` returns status and progress
   - `GET /jobs/{id}/file` streams the finished file
   - `GET /search?q=&source=` wraps yt-dlp search
   - `POST /update` updates yt-dlp
3. Put it behind **Tailscale** or a reverse proxy with **auth tokens**. Never expose it publicly without auth.
4. Clean up finished files after the phone confirms the download.

### 3.2 URL handling
1. **Share target.** Register an intent filter for `ACTION_SEND` text/plain so the user can press "Share → YourApp" in the YouTube, SoundCloud, or browser apps.
2. **Paste URL** field on the Download screen.
3. **Detect the source** from the domain: youtube.com / youtu.be / music.youtube.com, soundcloud.com, archive.org, *.bandcamp.com, etc.
4. **Playlists/albums.** Before downloading, use yt-dlp's `--flat-playlist -J` to list the entries so the user can pick tracks.

### 3.3 In-app search
- YouTube: `ytsearch10:<query>` (or `ytmsearch` style queries through YouTube Music URLs)
- SoundCloud: `scsearch10:<query>`
- Internet Archive: use the IA **Advanced Search API** (`mediatype:audio`) directly. It's faster and gives more detail than yt-dlp.
- Bandcamp: no official search API. Either link out to the site or let the user paste album URLs.

### 3.4 Recommended yt-dlp options (as concepts)

| Goal | Option |
|---|---|
| Best audio only | `-f bestaudio/best` |
| Extract audio | `-x` (`--extract-audio`) |
| Format choice | Keep the original (**opus/m4a**, no quality loss) **or** convert with `--audio-format mp3/m4a/opus/flac` + `--audio-quality 0` |
| Embed metadata | `--embed-metadata` (`--add-metadata`) |
| Embed cover | `--embed-thumbnail` + `--convert-thumbnails jpg` (square crop via ppa/ffmpeg args if wanted) |
| Clean filenames | `-o "%(artist,uploader)s/%(album,playlist_title|Singles)s/%(track_number,playlist_index|00)02d - %(track,title)s.%(ext)s"` + `--restrict-filenames` or `--windows-filenames` |
| Remove non-music parts of music videos | `--sponsorblock-remove music_offtopic` |
| Skip duplicates | `--download-archive archive.txt` |
| Parse "Artist - Title" from video titles | `--parse-metadata "title:%(artist)s - %(title)s"` |
| Better YouTube Music metadata | Prefer `music.youtube.com` URLs; they carry artist/album/track fields |
| Limit speed / retries | `--limit-rate`, `--retries`, `--fragment-retries` |
| Progress parsing | `--newline` + `--progress-template` for machine-readable progress |

> Note: YouTube tops out at ~160 kbps Opus / 128 kbps AAC. Converting to 320 kbps MP3 **does not add quality**, it only makes files bigger. Keep Opus/M4A where you can.

### 3.5 Download pipeline (per job)
1. Save a `DownloadJob` (QUEUED).
2. A WorkManager **foreground** worker (with a progress notification) runs yt-dlp.
3. Parse progress and update the DB, which updates the UI through Flow/Stream.
4. Post-process:
   1. Move the file into the music folder (MediaStore insert on Android 10+ so other apps can see it)
   2. Run **Identify** (Phase 4) → fix tags
   3. Run **Cover** (Phase 5) → embed hi-res art
   4. Run **Lyrics** (Phase 6) → save or embed
   5. ReplayGain analysis (optional)
   6. Insert into the Library DB
5. Mark it DONE or FAILED (with the error message and a "Retry" button).
6. Limit concurrency to 2–3 downloads. Only download on Wi-Fi if the user sets that.

### 3.6 Streaming without downloading (optional)
Use yt-dlp `-g` to get a direct stream URL and give it to ExoPlayer. These URLs **expire** (YouTube ~6 h), so fetch them again on playback. Include a "Download this" button.

**Deliverable:** share a YouTube/SoundCloud/IA/Bandcamp link to the app and a tagged file shows up in the library.

---

## Phase 4 — Metadata: MusicBrainz + AcoustID

### 4.1 Identification strategy (in order)
1. **Existing MBIDs in tags** → trust them and fetch the details.
2. **Acoustic fingerprint (best for YouTube rips):**
   1. Run **Chromaprint `fpcalc`** on the file to get `duration` + `fingerprint`
   2. Call **AcoustID** `/v2/lookup` with `meta=recordings+releasegroups+compress` → returns MusicBrainz recording IDs with a confidence score
   3. Accept automatically if the score is ≥ 0.9. Otherwise show the candidates to the user
3. **Text search fallback:** MusicBrainz `/ws/2/recording?query=` with `recording:"<title>" AND artist:"<artist>"` (+ `dur` range). Clean the title first (see 4.3).
4. **Manual.** The user searches and picks a match, or edits the tags by hand.

### 4.2 MusicBrainz calls you'll use
- `GET /ws/2/recording/{mbid}?inc=artists+releases+isrcs+genres+tags&fmt=json`
- `GET /ws/2/release/{mbid}?inc=recordings+artist-credits+labels+release-groups&fmt=json`
- `GET /ws/2/artist/{mbid}?inc=url-rels+genres&fmt=json` (url-rels give Wikidata, Discogs, and Bandcamp links)
- Search: `/ws/2/{recording|release|artist}?query=...&fmt=json`

**Rules:** `User-Agent` header required · ≤1 req/sec (queue them) · cache responses for a long time (MBIDs are stable).

**Picking the "right" release** when a recording is on many releases: prefer Official status → Album type → the original year (earliest date) → the user's country → a digital or CD format.

### 4.3 Title cleaning (for YouTube/SoundCloud titles)
Strip patterns such as `(Official Video)`, `[Official Audio]`, `(Lyrics)`, `(HD)`, `(4K Remaster)`, `| Visualizer`, `ft./feat.` (move these to the artist field), `- Topic` channel suffix, emoji, and hashtags. Keep a user-editable list of regex rules.

### 4.4 Tag writing
Write standard tags **plus** the MusicBrainz ones:
- Title, Artist, Album, AlbumArtist, Track/Disc #, Date, Genre, ISRC
- `MUSICBRAINZ_TRACKID`, `MUSICBRAINZ_ALBUMID`, `MUSICBRAINZ_ARTISTID`, `MUSICBRAINZ_RELEASEGROUPID`, `ACOUSTID_ID`
- Keep a `SOURCE_URL` / `COMMENT` tag with the original link

Use the Picard tag-mapping docs for the correct frame names per format (ID3v2.4 / Vorbis comments / MP4 atoms).

### 4.5 "Fix Tags" UI
- Batch "Identify all unmatched tracks" job
- A per-track review screen that shows **current vs. proposed** tags, the match confidence, and the cover preview → Accept / Reject / Pick another

**Deliverable:** a messy YouTube download becomes a properly tagged track, grouped under the correct album.

---

## Phase 5 — Cover Art

### 5.1 Priority chain
1. **Cover Art Archive (CAA)** by release MBID: `https://coverartarchive.org/release/{mbid}/front` (use the `-500` / `-1200` size suffixes for thumbnails)
2. CAA by **release-group** MBID: `/release-group/{mbid}/front` (useful when that exact release has no art)
3. **iTunes Search API** artwork (free, no key, change `100x100` in the URL to `1200x1200`)
4. **Deezer API** album `cover_xl` (free, no key)
5. **Last.fm** `album.getInfo` images
6. **Embedded thumbnail** from the yt-dlp download (YouTube thumbnails are 16:9, so **center-crop to a square**)
7. Generated placeholder (gradient + initials)

### 5.2 Handling
- Cache full-size art on disk. Generate thumbnails (e.g. 256 px) for lists.
- Embed ≤ 1200×1200 JPEG into the file (bigger embeds bloat files and some car stereos choke on them).
- Also save `cover.jpg` in the album folder (optional setting).
- Let the user replace art manually (from the gallery or by picking another search result).
- **Palette extraction** (AndroidX Palette / `palette_generator`) for dynamic Now Playing colors.

### 5.3 Artist images (extra)
- **fanart.tv** (by artist MBID, free key): artist thumbs, backgrounds, logos
- **TheAudioDB** (by MBID): artist photos, bios
- **Wikidata → Wikimedia Commons** image (P18 property) via the MB url-rels link
- Deezer artist `picture_xl`

**Deliverable:** every album shows high-quality art, and artist pages show photos.

---

## Phase 6 — Lyrics

### 6.1 Provider chain
1. **Embedded lyrics** in file tags (`USLT` for ID3 / `LYRICS` Vorbis / `©lyr` MP4) and a sidecar `.lrc` file next to the audio.
2. **LRCLIB** (lrclib.net): free, open, **no API key**, has **time-synced (LRC)** and plain lyrics.
   - `GET /api/get?track_name=&artist_name=&album_name=&duration=` (exact match)
   - `GET /api/search?q=` (fuzzy)
   - It also accepts community submissions, so you can contribute lyrics back.
3. **Genius API** (needs a token): use it for **song metadata, song art, description, and a "View on Genius" link/annotations** (`/search?q=`, `/songs/{id}`). The API gives no lyrics text. Scraping the web page breaks their ToS, so open the Genius page in a Custom Tab / WebView instead.
4. **Musixmatch** has an official API, but full lyrics need a commercial agreement. Skip it unless you get one.
5. **NetEase / QQ Music** lyric endpoints are used by some open-source players but are unofficial, so they're risky and can break.

### 6.2 Features
- **Synced lyrics view.** Parse LRC timestamps, highlight the current line, auto-scroll, tap a line to seek.
- Plain-text fallback view.
- Offset adjustment (±0.5 s) saved per track.
- Save to the DB and optionally embed in the file or write a `.lrc` sidecar.
- Manual edit / search a different match.

**Deliverable:** the Now Playing screen shows synced lyrics for most mainstream songs.

---

## Phase 7 — Extra Sources & Integrations

### 7.1 More download/stream sources (yt-dlp supports 1000+ sites)
| Source | Notes |
|---|---|
| **YouTube Music** | Use `music.youtube.com` URLs for cleaner artist/album metadata |
| **Audius** | Open, decentralized; has a free public API for search and streaming |
| **Jamendo** | Creative Commons music, official API (free client id), downloads allowed |
| **Free Music Archive** | CC-licensed catalog |
| **ccMixter** | CC remixes and a cappellas |
| **Mixcloud** | DJ mixes (yt-dlp supported) |
| **Vimeo / Twitch VODs** | Live sets (yt-dlp supported) |
| **Internet Archive Live Music Archive** (etree) | Thousands of legal live concerts in FLAC/MP3 |
| **Podcasts** | RSS feeds + **Podcast Index API** (free key); easy to add because your player already handles audio |
| **Internet Radio** | **Radio Browser API** (free, no key): 30k+ stations, search by tag/country |

Implement each one as a `SourceProvider` plugin: `search()`, `resolve(url)`, `download()`/`stream()`.

### 7.2 Metadata & discovery
| Service | Use |
|---|---|
| **Last.fm API** | Scrobbling, loved tracks, **similar artists/tracks**, top tags, artist bios |
| **ListenBrainz** | Open scrobbling alternative + recommendations (by MBID) |
| **Discogs API** | Detailed credits, vinyl/pressing info, extra genres/styles |
| **Wikipedia / Wikidata** | Artist bios, formation year, country, links |
| **Deezer API** | Fast search, BPM, previews, related artists, charts |
| **Spotify Web API** | Tracks and playlists metadata (for importing playlists as "wishlists" to find on other sources; the audio itself isn't downloadable) |
| **SponsorBlock** | Handled by yt-dlp to cut intros/outros from music videos |
| **AcoustID** | Already used for fingerprinting |

### 7.3 Nice-to-have features built on these
- **Playlist import.** Paste a Spotify/Deezer/YouTube playlist URL → match each track → queue downloads for the ones you're missing.
- **"Radio" mode.** Seed from the current track → Last.fm/ListenBrainz similar tracks → play what's local, suggest downloads for the rest.
- **New release alerts.** Watch followed artists through MusicBrainz release-group browse and notify.
- **Scrobble queue** that works offline and syncs later.

---

## Phase 8 — UI/UX

### Screens
1. **Home.** Recently played, recently added, most played, suggestions, in-progress downloads.
2. **Library.** Tabs: Songs · Albums · Artists · Genres · Folders · Playlists; sort and filter; grid/list toggle.
3. **Album / Artist detail.** Big art, bio, track list, "download missing tracks" (compare against the MB tracklist).
4. **Now Playing.** Art, dynamic colors, seek bar (with waveform, optional), controls, queue sheet, lyrics toggle, sleep timer, EQ, "Fix tags".
5. **Mini-player** always visible above the bottom navigation.
6. **Search.** One box, results grouped **Local | YouTube | SoundCloud | Internet Archive | Bandcamp | …** with a download button on each remote result.
7. **Downloads.** Active/queued/finished/failed, retry, cancel, and logs.
8. **Tag editor / Identify review.**
9. **Settings** (see Phase 9).

### Design tips
- Material 3 / Material You dynamic color on Android 12+.
- Light/Dark/AMOLED-black themes.
- Gestures: swipe the mini-player to skip, swipe down to close Now Playing, long-press for a context menu.
- Accessibility: content descriptions, large-font support, good contrast.
- Home-screen widget (Glance for Compose) (optional).

---

## Phase 9 — Settings, Background Work, Storage

### Settings
- **Downloads.** Output folder, format (original/opus/m4a/mp3/flac), quality, filename template, Wi-Fi only, max concurrent, SponsorBlock on/off, auto-identify, auto-cover, auto-lyrics.
- **Downloader engine.** On-device vs. server URL + token; "Update yt-dlp now"; stable/nightly channel; cookies file (for age-restricted or members content, used on your own account).
- **Library.** Scan folders, exclude folders, minimum duration (skip ringtones/voice notes), ignore "WhatsApp Audio".
- **Metadata.** Enable/disable/reorder providers; auto-accept threshold; preferred release country; write tags to files yes/no.
- **Playback.** Gapless, crossfade, ReplayGain mode (track/album/off), resume on headphone connect, audio focus behavior.
- **Accounts.** Last.fm, ListenBrainz, Genius tokens.
- **Backup/Restore.** Export the DB (playlists, play counts, ratings) as JSON/zip.

### Storage (Android 10+ scoped storage)
- Write downloads through **MediaStore** (`Music/YourApp/...`) so other apps can see them without broad permissions.
- Editing tags on files the app didn't create needs `MediaStore.createWriteRequest` (user confirmation) on Android 11+.
- Avoid `MANAGE_EXTERNAL_STORAGE` unless you really need it (fine for sideloaded apps, but it's a big permission).

### Background work
- WorkManager with **foreground service type `dataSync`** for downloads (Android 14 requires a declared FGS type).
- Playback service type `mediaPlayback`.
- Handle Doze and battery-optimization prompts (ask the user to exempt the app if downloads get killed).

---

## Phase 10 — Testing

1. **Unit tests.** Title cleaner, LRC parser, release-picking logic, filename templating, rate limiter.
2. **Provider tests with recorded responses.** Save real JSON from MB/AcoustID/LRCLIB/CAA as fixtures and run them with MockWebServer.
3. **DB tests.** Room migrations (write a migration for every schema change from v1 on).
4. **Playback tests.** Queue operations, persistence across process death.
5. **Instrumented tests.** Permissions flow, share-intent flow, download → library appearance.
6. **Manual test matrix.** Android 8, 10, 13, 14, 15; a low-RAM device; Bluetooth, car, and wired headphones.
7. **Canary check for yt-dlp.** A weekly CI job that downloads a known Creative Commons test video, so you notice breakage early.

---

## Phase 11 — Build & Release

1. **Signing.** Create a release keystore and **back it up** (if you lose it you can't ship updates).
2. **R8/ProGuard** rules (youtubedl-android, jaudiotagger, and serialization need keep rules).
3. **ABI-split APKs** to reduce size.
4. **Distribution**
   - GitHub Releases (+ in-app update check through the GitHub Releases API)
   - **Obtainium** users can track your GitHub releases automatically
   - F-Droid (needs reproducible builds and FOSS dependencies; YouTube features get the anti-feature label)
   - iOS: AltStore/SideStore source or TestFlight for personal use only
5. **Changelog + versioning** (SemVer).
6. **Crash reporting.** ACRA (self-hosted, privacy-friendly) instead of Firebase if you want to stay FOSS.

---

## API & Service Reference

| Service | Base URL | Auth | Rate limit / notes |
|---|---|---|---|
| MusicBrainz | `https://musicbrainz.org/ws/2/` | None (User-Agent required) | 1 req/s |
| Cover Art Archive | `https://coverartarchive.org/` | None | Redirects to archive.org; follow redirects |
| AcoustID | `https://api.acoustid.org/v2/lookup` | App key | 3 req/s |
| Chromaprint (fpcalc) | local binary | — | Generates the fingerprint |
| LRCLIB | `https://lrclib.net/api/` | None | Send a User-Agent; be polite |
| Genius | `https://api.genius.com/` | Bearer token | Metadata + URLs only, no lyrics text |
| Last.fm | `https://ws.audioscrobbler.com/2.0/` | API key (+ session for scrobbling) | ~5 req/s guideline |
| ListenBrainz | `https://api.listenbrainz.org/1/` | User token | Follow rate-limit headers |
| Deezer | `https://api.deezer.com/` | None for public data | 50 req / 5 s |
| iTunes Search | `https://itunes.apple.com/search` | None | ~20 req/min |
| Discogs | `https://api.discogs.com/` | Token | 60 req/min authenticated |
| fanart.tv | `https://webservice.fanart.tv/v3/music/{mbid}` | API key | — |
| TheAudioDB | `https://www.theaudiodb.com/api/v1/json/{key}/` | Free/test key | — |
| Internet Archive | `https://archive.org/advancedsearch.php`, `/metadata/{id}` | None | Be polite |
| Radio Browser | `https://de1.api.radio-browser.info/json/` | None | Pick a server via DNS |
| Podcast Index | `https://api.podcastindex.org/api/1.0/` | Key + secret | — |
| Jamendo | `https://api.jamendo.com/v3.0/` | Client id | — |
| Audius | discovery node from `https://api.audius.co` | None (app name param) | — |

Useful docs to bookmark:
- yt-dlp README (options, output template, format selection)
- youtubedl-android GitHub README
- MusicBrainz API docs + search syntax
- MusicBrainz Picard "Tag Mapping" page
- AcoustID Web Service docs
- LRC format (Wikipedia "LRC (file format)")
- AndroidX Media3 docs (MediaSessionService, MediaLibraryService)
- Android scoped storage / MediaStore guides

Open-source apps worth studying for patterns (don't copy code without following their licenses):
- **Seal**: Android yt-dlp GUI (youtubedl-android usage, download UI)
- **ytdlnis**: another yt-dlp Android front-end
- **Auxio**, **Gramophone**: modern Media3 local players
- **InnerTune / Metrolist / ViMusic**: YouTube Music clients
- **MusicBrainz Picard**: reference implementation of matching logic
- **beets**: CLI music organizer; great matching and plugin ideas

---

## Common Pitfalls

1. **yt-dlp breaks.** YouTube changes things constantly. Ship an in-app updater from day one.
2. **Ignoring MusicBrainz rate limits** gets your IP blocked. Use one global queue.
3. **Trusting the video title.** Always fingerprint first; titles are unreliable.
4. **16:9 thumbnails as album art** look wrong. Crop to a square or prefer CAA.
5. **Scoped storage surprises.** Test file writes and tag edits on Android 11+ early.
6. **Killed background downloads.** Use foreground workers and ask for a battery-optimization exemption.
7. **Huge APK.** Use ABI splits; ffmpeg is the biggest part.
8. **Duplicate tracks.** Dedupe by `sourceUrl`, `mbRecordingId`, and audio hash before inserting.
9. **Expired stream URLs** when streaming YouTube. Re-resolve when playback fails with 403.
10. **No DB migrations.** Users lose play counts and playlists. Write migrations from v1.
11. **Committing API keys.** Use local config + CI secrets.

---

## Milestone Checklist

- [ ] **M0** Project skeleton, CI, API keys registered
- [ ] **M1** Play a local file with background/notification controls
- [ ] **M2** Full local library scan + search + playlists + queue persistence
- [ ] **M3** yt-dlp download from a pasted/shared URL (YouTube, SoundCloud, IA, Bandcamp)
- [ ] **M4** Download manager UI (queue, progress, retry, update yt-dlp)
- [ ] **M5** AcoustID + MusicBrainz auto-identify and tag writing
- [ ] **M6** Cover Art Archive + fallbacks, embedded art, dynamic colors
- [ ] **M7** LRCLIB synced lyrics + Genius info link
- [ ] **M8** Unified search across local and remote sources
- [ ] **M9** Scrobbling (Last.fm / ListenBrainz), artist pages (bios, images)
- [ ] **M10** Extras: radio, podcasts, playlist import, smart playlists
- [ ] **M11** Polish, tests, signed release on GitHub

Suggested pace for one developer working part-time: **M0–M2 ≈ 3–4 weeks, M3–M4 ≈ 2–3 weeks, M5–M7 ≈ 3–4 weeks, M8–M11 ≈ 4+ weeks.**

---

## Future Ideas

- **Stem separation / karaoke mode** (Demucs on the server)
- **Auto-DJ with BPM/key detection** (Essentia, or aubio on the server) for smooth transitions
- **Waveform seek bar** generated at download time
- **Sync between devices** through your server (play counts, playlists)
- **Chromecast / DLNA / UPnP** output
- **Wear OS** and **Android Auto** companion UIs
- **Subsonic/Navidrome/Jellyfin client mode**: stream your home library with the same UI
- **Plugin system** so new sources can be added without app updates (e.g. JS/Lua scripts)
