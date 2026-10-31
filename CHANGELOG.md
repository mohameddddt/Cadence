# Changelog

All notable changes are documented here. The project follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Lumen design language: warm paper and ink neutrals generated from the palette's hue, a single accent, Instrument Serif titles with Manrope text, pill chips and buttons, and editorial screen titles.
- Seven palettes (Coral, Sage, Ocean, Amber, Rose, Violet, Ink) and six typeface pairings (Editorial, Classic, Modern, Rounded, Cadence, System), with live previews in Appearance.
- Floating frosted-glass dock and glass mini player with a shared-element transition into Now Playing.
- Now Playing: blurred cover backdrop (Ambient backdrop setting) and cover colours that tint the whole page.
- Home: time-of-day greeting, Shuffle all / Favourites / Radio / Podcasts shortcuts, Jump back in card and ranked Most played list.
- Animated playing bars on the current song in every list.
- Pure black is now a switch that works with any theme; the old AMOLED choice carries over.
- Clean typeface pairing (Plus Jakarta Sans), now the default for titles and text.
- Custom colour: pick any hue with a rainbow slider or quick swatches and choose how much it tints the background, with a live preview. A palette button on Home opens Colours & fonts.
- Playlists come first in Library, shown as a cover grid with Favourites / Recent / Top shortcuts.
- Create and edit playlists with a name and a picture (cropped to a square and kept in app storage). The database moves to schema v2 to store it; existing playlists are kept.

- New look: near-black surfaces, a green accent (still changeable), bold Plus Jakarta Sans titles, filled chips and small corner radii.
- Full-width bottom bar (Home, Search, Your Library, Downloads, Dashboard) over a fade to black, and a mini player tinted with the cover's colour with a save toggle.
- Home: quick-tile grid (Liked songs, Shuffle all and recent songs), Recently added, Your top artists and On repeat shelves.
- Search: white search bar; before you type it shows recent searches, Radio and Podcasts, a Surprise me mix, Your genres (from your tags, with your covers) and Through the decades (from release years).
- Your Library: chips instead of tabs, a sort control, pinned Liked songs / Recently played / On repeat, and list or grid playlists.
- Playlist and album pages open on a gradient from the cover's colour with a large cover, shuffle and a big play button.
- Now Playing: cover-colour gradient, large square art, save toggle, white play button, and a lyrics card below the player.

### Fixed
- Text and icons on light accents in dark mode now use ink instead of white, so they keep enough contrast.

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
