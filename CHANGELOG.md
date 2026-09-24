# Changelog

All notable changes are documented here. The project follows [Semantic Versioning](https://semver.org/).

## [0.1.0]

First release, covering every phase of the plan.

### Added
- Local playback: background service with notification / lock screen / Bluetooth / Android Auto browse tree, gapless queue with persistence across restarts, shuffle & repeat, ReplayGain (track/album, positive gain through the loudness enhancer), equalizer + loudness boost, sleep timer (minutes or end of song), fade between songs, audio-focus ducking and headphone handling.
- Library: incremental MediaStore + folder (SAF) scanning, album grouping with compilations and MusicBrainz ids, full-text search, songs/albums/artists/genres/folders views, playlists and smart playlists, backup/restore.
- Downloads: on-device yt-dlp (+ffmpeg, aria2c) with in-app updates and automatic update-and-retry, companion server for iOS, direct HTTP for Internet Archive / Audius / Jamendo / ccMixter / podcasts and bare links to audio files (`…/song.mp3`, http or https), share-target, playlist expansion, queue with concurrency limit, Wi-Fi-only, resume after app kill, foreground service, duplicate detection (URL, MusicBrainz id, audio hash).
- Metadata: Chromaprint fingerprinting (pure-Dart port validated against `fpcalc`), AcoustID + MusicBrainz identification with release picking, title cleaner, tag writer (MP3/FLAC/M4A/OGG) including MusicBrainz ids, review UI, batch identification.
- Cover art chain (Cover Art Archive → iTunes → Deezer → Last.fm → embedded) with square crop, embedding and manual selection; lyrics from tags, `.lrc`, LRCLIB (synced), Genius info link.
- Integrations: Last.fm and ListenBrainz scrobbling with an offline queue, artist pages (bio, photos, links, discography, missing albums), radio from similar tracks, internet radio, podcasts, playlist import (Spotify/Deezer/YouTube) with wishlist, new-release alerts.
- Material 3 UI with dynamic colour, light/dark/AMOLED themes and cover-derived Now Playing colours.
