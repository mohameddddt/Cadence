import 'dart:async';
import 'dart:io';

import '../../core/library/library_repository.dart';
import '../../core/models/track.dart';
import '../../core/settings/settings_store.dart';
import '../../platform/bridges.dart';
import '../downloader/source_detect.dart';

class ScanProgress {
  const ScanProgress(this.phase, this.done, this.total);
  final String phase; // listing | reading | cleaning | done
  final int done;
  final int total;
}

class ScanResult {
  const ScanResult({this.added = 0, this.updated = 0, this.removed = 0, this.skipped = 0, this.failed = 0, this.total = 0});
  final int added;
  final int updated;
  final int removed;
  final int skipped;
  final int failed;
  final int total;

  @override
  String toString() => 'ScanResult(added: $added, updated: $updated, removed: $removed, skipped: $skipped, failed: $failed, total: $total)';
}

/// Keeps the tracks table in sync with the files on the device.
///
/// 1. lists audio through MediaStore plus every persisted Storage-Access-Framework folder,
/// 2. re-reads tags only for new or changed files (size + mtime, the "incremental rescan"),
/// 3. removes rows whose file is gone,
/// 4. re-scans automatically when MediaStore reports a change.
class LibraryScanner {
  LibraryScanner({
    required this.repo,
    required this.bridges,
    required this.settings,
    this.readConcurrency = 4,
    this.batchSize = 40,
    bool Function(String path)? fileExists,
  }) : _fileExists = fileExists ?? ((p) => File(p).existsSync());

  final LibraryRepository repo;
  final Bridges bridges;
  final SettingsStore settings;
  final int readConcurrency;
  final int batchSize;
  final bool Function(String path) _fileExists;

  Future<ScanResult>? _running;
  StreamSubscription<void>? _watch;
  Timer? _debounce;

  final StreamController<ScanProgress> _progress = StreamController<ScanProgress>.broadcast();
  Stream<ScanProgress> get progress => _progress.stream;

  bool get isScanning => _running != null;

  /// Starts watching MediaStore for changes and rescans (debounced) when it fires.
  void startWatching({Duration debounce = const Duration(seconds: 3)}) {
    _watch?.cancel();
    _watch = bridges.mediaStore.changes.listen((_) {
      _debounce?.cancel();
      _debounce = Timer(debounce, () => scan());
    }, onError: (_) {});
  }

  Future<void> dispose() async {
    _debounce?.cancel();
    await _watch?.cancel();
    await _progress.close();
  }

  /// Single-flight: concurrent callers share the running scan.
  Future<ScanResult> scan({bool force = false}) {
    return _running ??= _scan(force: force).whenComplete(() {
      _running = null;
    });
  }

  Future<ScanResult> _scan({required bool force}) async {
    _progress.add(const ScanProgress('listing', 0, 0));

    // Snapshot the database BEFORE listing the device. A track added meanwhile (a download
    // finishing) is then unknown to this scan and can never be mistaken for a deleted file.
    final index = await repo.scanIndex();

    // ---- 1. list -------------------------------------------------------------
    final listed = <String, AudioFileInfo>{};
    var listingFailed = false;
    try {
      for (final f in await bridges.mediaStore.queryAudio()) {
        listed[f.key] = f;
      }
    } on PlatformFailure {
      listingFailed = true;
    }
    try {
      for (final folder in await bridges.mediaStore.persistedFolders()) {
        try {
          for (final f in await bridges.mediaStore.scanTree(folder.uri)) {
            // MediaStore data is richer (and its path is canonical): keep it when both see the file.
            listed.putIfAbsent(f.key, () => f);
          }
        } on PlatformFailure {
          listingFailed = true;
        }
      }
    } on PlatformFailure {
      // SAF unavailable - MediaStore results still count.
    }

    // ---- 2. filter -------------------------------------------------------------
    final excluded = settings.excludedFolders;
    final minMs = settings.minDurationSec * 1000;
    final keep = <String, AudioFileInfo>{};
    final filteredOut = <String>{};
    // The short-clip filter is there for ringtones and voice notes. A track the user downloaded
    // or imported on purpose (a jingle, a short SoundCloud upload) must never be swept away by it.
    bool isDownloaded(String key) => (index[key]?.source ?? 'local') != 'local';
    for (final e in listed.entries) {
      final info = e.value;
      if (_isExcluded(info, excluded) || (settings.ignoreMessagingAudio && _isMessagingAudio(info))) {
        filteredOut.add(e.key);
        continue;
      }
      // Duration is known for MediaStore rows; SAF rows are checked after the tag read.
      if (info.durationMs != null && info.durationMs! > 0 && info.durationMs! < minMs && !isDownloaded(e.key)) {
        filteredOut.add(e.key);
        continue;
      }
      keep[e.key] = info;
    }

    // ---- 3. diff against the database (snapshot taken above) ---------------------------
    // Refuse to interpret "we got nothing" as "everything was deleted" when listing broke.
    final canDelete = !listingFailed && (listed.isNotEmpty || index.isEmpty);

    final toRead = <AudioFileInfo>[];
    var skipped = 0;
    for (final info in keep.values) {
      final known = index[info.key];
      if (!force && known != null && known.mtime == info.dateModified && (info.size == 0 || known.size == info.size)) {
        skipped++;
        continue;
      }
      toRead.add(info);
    }

    // ---- 4. read tags + write rows ---------------------------------------------------
    var added = 0, updated = 0, failed = 0;
    var done = 0;
    _progress.add(ScanProgress('reading', 0, toRead.length));
    for (var i = 0; i < toRead.length; i += batchSize) {
      final batch = toRead.sublist(i, i + batchSize > toRead.length ? toRead.length : i + batchSize);
      final drafts = <TrackDraft>[];
      for (var j = 0; j < batch.length; j += readConcurrency) {
        final slice = batch.sublist(j, j + readConcurrency > batch.length ? batch.length : j + readConcurrency);
        final results = await Future.wait(slice.map((info) async {
          TagData? tags;
          try {
            tags = await bridges.tags.read(path: info.path, uri: info.uri);
          } on PlatformFailure {
            failed++;
          } catch (_) {
            failed++;
          }
          return (info, tags);
        }));
        for (final (info, tags) in results) {
          final draft = buildDraft(info, tags);
          if (draft.durationMs > 0 && draft.durationMs < minMs && !isDownloaded(info.key)) {
            // Found out only now (SAF rows): too short to be music.
            filteredOut.add(info.key);
            final existing = index[info.key];
            if (existing != null) await repo.deleteTracks([existing.id]);
            continue;
          }
          if (index.containsKey(info.key)) {
            updated++;
          } else {
            added++;
          }
          drafts.add(draft);
        }
        done += slice.length;
        _progress.add(ScanProgress('reading', done, toRead.length));
      }
      if (drafts.isNotEmpty) await repo.upsertTracks(drafts);
    }

    // ---- 5. removals ----------------------------------------------------------------
    var removed = 0;
    if (canDelete) {
      _progress.add(const ScanProgress('cleaning', 0, 0));
      final gone = <int>[];
      for (final e in index.entries) {
        final key = e.key;
        if (keep.containsKey(key)) continue;
        if (filteredOut.contains(key)) {
          gone.add(e.value.id);
          continue;
        }
        // Not listed at all. If the file is really still there (hidden by .nomedia or a
        // MediaStore hiccup) keep it; otherwise the file was deleted or moved.
        if (key.startsWith('/') && _fileExists(key)) continue;
        gone.add(e.value.id);
      }
      if (gone.isNotEmpty) removed = await repo.deleteTracks(gone);
    }

    final total = await repo.trackCount();
    _progress.add(ScanProgress('done', toRead.length, toRead.length));
    return ScanResult(added: added, updated: updated, removed: removed, skipped: skipped, failed: failed, total: total);
  }

  // ---------------------------------------------------------------- helpers

  static bool _isExcluded(AudioFileInfo info, List<String> excluded) {
    if (excluded.isEmpty) return false;
    final path = info.path ?? '';
    final rel = info.relativePath ?? '';
    for (final ex in excluded) {
      if (ex.isEmpty) continue;
      if (path.isNotEmpty && (path == ex || path.startsWith(ex.endsWith('/') ? ex : '$ex/'))) return true;
      if (rel.isNotEmpty && (rel == ex || rel.startsWith(ex.endsWith('/') ? ex : '$ex/'))) return true;
    }
    return false;
  }

  static final RegExp _messaging = RegExp(
    r'(whatsapp|telegram|signal|viber|messenger|voice ?notes?|voice ?recorder|sound ?recorder|call ?recordings?|recordings/call)',
    caseSensitive: false,
  );

  static bool _isMessagingAudio(AudioFileInfo info) {
    final p = '${info.path ?? ''}/${info.relativePath ?? ''}';
    return _messaging.hasMatch(p);
  }

  /// Merges MediaStore facts with tag data. Tags win for anything they contain.
  /// MediaStore's album is deliberately ignored when a tag read succeeded: it fills the
  /// folder name in for untagged files, which would create bogus albums.
  static TrackDraft buildDraft(AudioFileInfo info, TagData? tags) {
    final base = (info.displayName ?? info.key.split('/').last);
    final stem = base.contains('.') ? base.substring(0, base.lastIndexOf('.')) : base;
    final ext = base.contains('.') ? base.substring(base.lastIndexOf('.') + 1).toUpperCase() : null;

    String? clean(String? s) {
      final t = s?.trim();
      if (t == null || t.isEmpty || t == '<unknown>') return null;
      return t;
    }

    final tagOk = tags != null;
    final sourceUrl = clean(tags?.sourceUrl);
    var source = TrackSource.local;
    if (sourceUrl != null) {
      final detected = detectSource(sourceUrl).source;
      if (detected != TrackSource.other) source = detected;
    }
    return TrackDraft(
      filePath: info.key,
      contentUri: info.uri.isEmpty ? null : info.uri,
      folder: info.folder,
      title: clean(tags?.title) ?? clean(info.title) ?? stem,
      artist: clean(tags?.artist) ?? clean(info.artist),
      albumArtist: clean(tags?.albumArtist) ?? clean(info.albumArtist),
      album: tagOk ? clean(tags.album) : clean(info.album),
      trackNo: tags?.trackNo ?? info.trackNo,
      discNo: tags?.discNo ?? info.discNo,
      durationMs: (tags?.durationMs ?? 0) > 0 ? tags!.durationMs! : (info.durationMs ?? 0),
      year: tags?.year ?? info.year,
      genre: clean(tags?.genre) ?? clean(info.genre),
      bitrate: tags?.bitrate ?? info.bitrate,
      format: ext ?? tags?.format,
      sizeBytes: info.size,
      fileMtime: info.dateModified,
      dateAdded: info.dateAdded,
      source: source,
      sourceUrl: sourceUrl,
      mbRecordingId: clean(tags?.mbRecordingId),
      mbReleaseId: clean(tags?.mbReleaseId),
      mbReleaseGroupId: clean(tags?.mbReleaseGroupId),
      mbArtistId: clean(tags?.mbArtistId),
      acoustId: clean(tags?.acoustId),
      isrc: clean(tags?.isrc),
      replayGainTrack: _gain(tags?.replayGainTrack),
      replayGainAlbum: _gain(tags?.replayGainAlbum),
      hasEmbeddedArt: tags?.hasArt ?? false,
    );
  }

  static double? _gain(String? s) {
    if (s == null) return null;
    final m = RegExp(r'[-+]?\d+(?:[.,]\d+)?').firstMatch(s);
    return m == null ? null : double.tryParse(m.group(0)!.replaceAll(',', '.'));
  }
}
