import 'dart:io';

import '../../core/library/library_repository.dart';
import '../../core/models/library_models.dart';
import '../../core/models/track.dart';
import '../../core/settings/settings_store.dart';
import '../../platform/bridges.dart';
import '../metadata/tag_writer.dart';
import '../metadata/title_cleaner.dart';
import 'lrc_parser.dart';
import 'lyrics_clients.dart';

/// Lyrics provider chain (plan phase 6): embedded tags + sidecar .lrc first, then LRCLIB.
/// Genius is used for song info and a link only (its API does not return lyrics text).
class LyricsService {
  LyricsService({
    required this.repo,
    required this.bridges,
    required this.settings,
    required this.lrclib,
    required this.genius,
    required this.tagWriter,
  });

  final LibraryRepository repo;
  final Bridges bridges;
  final SettingsStore settings;
  final LrclibClient lrclib;
  final GeniusClient genius;
  final TagWriter tagWriter;

  /// Stored lyrics only - never touches the network.
  Future<LyricsRow?> cached(Track t) => repo.lyricsForTrack(t.id);

  /// Returns lyrics for [t], fetching them when there are none stored (or [refresh]).
  /// A miss is remembered as an empty row so we do not hammer LRCLIB on every play.
  Future<LyricsRow?> lyricsFor(Track t, {bool refresh = false, Duration retryMissesAfter = const Duration(days: 7)}) async {
    final existing = await repo.lyricsForTrack(t.id);
    if (existing != null && !refresh) {
      if (existing.hasAny || existing.instrumental) return existing;
      final age = DateTime.now().millisecondsSinceEpoch ~/ 1000 - existing.fetchedAt;
      if (age < retryMissesAfter.inSeconds) return null;
    }

    var anyFailed = false;
    for (final id in settings.lyricsProviders) {
      _Found? found;
      try {
        found = switch (id) {
          'embedded' => await _embedded(t),
          'lrclib' => await _lrclib(t),
          _ => null,
        };
      } on Exception {
        anyFailed = true;
        continue; // offline or provider down: try the next one
      }
      if (found == null) continue;
      await repo.saveLyrics(t.id, plainText: found.plain, syncedLrc: found.synced, source: found.source, instrumental: found.instrumental);
      if (found.source != 'embedded') await _persistToFiles(t, found);
      return repo.lyricsForTrack(t.id);
    }
    // Remember a genuine miss (empty row) - but not a failure, so we retry when back online.
    if (!anyFailed) await repo.saveLyrics(t.id, source: 'none');
    return null;
  }

  Future<_Found?> _embedded(Track t) async {
    // Sidecar next to the audio file wins: it is the user's own file.
    if (t.hasRealPath) {
      final base = t.filePath.contains('.') ? t.filePath.substring(0, t.filePath.lastIndexOf('.')) : t.filePath;
      try {
        final f = File('$base.lrc');
        if (f.existsSync()) {
          final text = f.readAsStringSync();
          if (text.trim().isNotEmpty) return _classify(text, 'sidecar');
        }
      } on FileSystemException {
        // scoped storage may hide non-media files: fine, fall through to the tags
      }
    }
    try {
      final tags = await bridges.tags.read(path: t.hasRealPath ? t.filePath : null, uri: t.contentUri);
      final text = tags.lyrics;
      if (text != null && text.trim().isNotEmpty) return _classify(text, 'embedded');
    } on PlatformFailure {
      // unreadable tags
    }
    return null;
  }

  _Found _classify(String text, String source) {
    if (LrcDocument.looksSynced(text)) {
      final doc = LrcDocument.parse(text);
      return _Found(source: source, synced: text, plain: doc.plainText);
    }
    return _Found(source: source, plain: text);
  }

  Future<_Found?> _lrclib(Track t) async {
    final cleaned = TitleCleaner.fromSettings(settings.titleRules).clean(t.title, uploader: t.artistName);
    final title = cleaned.title;
    final artist = t.artistName ?? cleaned.artist;
    if (artist == null || artist.isEmpty) return null;
    final seconds = t.durationMs > 0 ? (t.durationMs / 1000).round() : null;

    var r = await lrclib.get(title: title, artist: artist, album: t.albumTitle, durationSec: seconds);
    if (r == null && t.albumTitle != null) {
      // Album spelling differs between databases often; retry without it.
      r = await lrclib.get(title: title, artist: artist, durationSec: seconds);
    }
    if (r == null || (!r.hasAny && !r.instrumental)) {
      final hits = await lrclib.search(title: title, artist: artist);
      r = LrclibClient.bestMatch(hits, title: title, artist: artist, durationSec: seconds);
    }
    if (r == null) return null;
    return _Found(source: 'lrclib', plain: r.plain, synced: r.hasSynced ? r.synced : null, instrumental: r.instrumental);
  }

  /// Optionally embed into the file / write a .lrc sidecar (settings).
  Future<void> _persistToFiles(Track t, _Found f) async {
    if (settings.embedLyrics && settings.writeTagsToFiles) {
      final text = f.synced ?? f.plain;
      if (text != null && text.isNotEmpty) {
        await tagWriter.write(t, TagUpdate({'lyrics': text}));
      }
    }
    if (settings.writeLrcSidecar && f.synced != null && t.hasRealPath) {
      final base = t.filePath.contains('.') ? t.filePath.substring(0, t.filePath.lastIndexOf('.')) : t.filePath;
      try {
        File('$base.lrc').writeAsStringSync(f.synced!);
      } on FileSystemException {
        // not permitted in this folder under scoped storage
      }
    }
  }

  // ----------------------------------------------------- manual choices

  Future<List<LrclibResult>> searchAlternatives(String query) => lrclib.search(query: query);

  /// The user picked a result from [searchAlternatives].
  Future<LyricsRow?> choose(Track t, LrclibResult r) async {
    final found = _Found(source: 'lrclib', plain: r.plain, synced: r.hasSynced ? r.synced : null, instrumental: r.instrumental);
    await repo.saveLyrics(t.id, plainText: found.plain, syncedLrc: found.synced, source: 'lrclib', instrumental: found.instrumental);
    await _persistToFiles(t, found);
    return repo.lyricsForTrack(t.id);
  }

  /// Hand-edited lyrics. Synced when [text] carries LRC timestamps.
  Future<LyricsRow?> saveManual(Track t, String text) async {
    final f = _classify(text, 'manual');
    await repo.saveLyrics(t.id, plainText: f.plain, syncedLrc: f.synced, source: 'manual');
    await _persistToFiles(t, f);
    return repo.lyricsForTrack(t.id);
  }

  Future<void> setOffset(Track t, int offsetMs) => repo.setLyricsOffset(t.id, offsetMs);

  /// Song page + description from Genius (needs a token). Opened in a browser, not scraped.
  Future<GeniusSong?> geniusInfo(Track t) async {
    if (!genius.isConfigured) return null;
    final cleaned = TitleCleaner.fromSettings(settings.titleRules).clean(t.title, uploader: t.artistName);
    final m = await genius.match(title: cleaned.title, artist: t.artistName ?? cleaned.artist);
    if (m == null) return null;
    return await genius.song(m.id) ?? m;
  }
}

class _Found {
  const _Found({required this.source, this.plain, this.synced, this.instrumental = false});
  final String source;
  final String? plain;
  final String? synced;
  final bool instrumental;
}
