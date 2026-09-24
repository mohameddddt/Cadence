import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart';

import '../../core/library/library_repository.dart';
import '../../core/models/library_models.dart';
import '../../core/models/track.dart';
import '../../core/net/http_service.dart';
import '../../core/settings/settings_store.dart';
import '../../platform/bridges.dart';
import '../metadata/tag_writer.dart';
import '../playback/audio_handler.dart';
import '../playback/media_items.dart';
import 'cover_providers.dart';
import 'image_processing.dart';

/// Finds, caches and embeds album art. Provider order comes from the settings; the
/// embedded thumbnail (e.g. yt-dlp's) is the last resort before the UI's generated placeholder.
class CoverService implements ArtworkResolver {
  CoverService({
    required this.repo,
    required this.http,
    required this.bridges,
    required this.settings,
    required this.providers,
    required this.tagWriter,
    required this.coversDir,
    Future<Uint8List> Function(Uint8List)? processor,
  }) : _process = processor ?? ImageProcessing.processCoverAsync;

  final LibraryRepository repo;
  final HttpService http;
  final Bridges bridges;
  final SettingsStore settings;
  final Map<String, CoverProvider> providers;
  final TagWriter tagWriter;
  final Directory Function() coversDir;
  final Future<Uint8List> Function(Uint8List) _process;

  final Map<int, Future<File?>> _inFlight = {};

  File _albumFile(int albumId) => File('${coversDir().path}/album_$albumId.jpg');
  File _trackFile(int trackId) => File('${coversDir().path}/track_$trackId.jpg');

  // ---------------------------------------------------------------- lookups

  /// Cached cover file for an album if it exists (cheap, no network).
  File? cachedAlbumCover(Album a) {
    final p = a.coverPath;
    if (p != null && File(p).existsSync()) return File(p);
    return null;
  }

  /// Runs the provider chain for [q] and returns the first hit.
  Future<CoverCandidate?> findRemote(CoverQuery q) async {
    for (final id in settings.coverProviders) {
      if (id == 'embedded') continue;
      final p = providers[id];
      if (p == null) continue;
      try {
        final c = await p.find(q);
        if (c != null) return c;
      } on Object {
        continue; // one failing (or oddly answering) provider must not stop the chain
      }
    }
    return null;
  }

  /// Options for the manual "pick another cover" dialog.
  Future<List<CoverCandidate>> searchCandidates(CoverQuery q) async {
    final out = <CoverCandidate>[];
    for (final p in providers.values) {
      try {
        out.addAll(await p.candidates(q));
      } on Object {
        continue;
      }
    }
    return out;
  }

  /// Downloads [c], crops/resizes it and stores it as the album's cover.
  Future<File?> useCandidate(Album album, CoverCandidate c) async {
    final bytes = Uint8List.fromList(await http.getBytes(c.url));
    final jpg = await _process(bytes);
    final f = _albumFile(album.id)..parent.createSync(recursive: true);
    await f.writeAsBytes(jpg, flush: true);
    await repo.updateAlbum(album.id, coverPath: f.path, coverSource: c.source);
    return f;
  }

  /// Ensures [album] has a cover: cache -> providers -> embedded art of one of its tracks.
  Future<File?> ensureAlbumCover(Album album, {bool force = false}) {
    if (!force) {
      final cached = cachedAlbumCover(album);
      if (cached != null) return Future.value(cached);
    }
    return _inFlight[album.id] ??= _fetchAlbumCover(album, force).whenComplete(() {
          // A block body: returning the removed future would make it wait on itself.
          _inFlight.remove(album.id);
        });
  }

  Future<File?> _fetchAlbumCover(Album album, bool force) async {
    // 1. remote providers
    final q = CoverQuery(
      artist: album.compilation ? null : album.artistName,
      album: album.title,
      mbReleaseId: album.mbReleaseId,
      mbReleaseGroupId: album.mbReleaseGroupId,
    );
    final remote = await findRemote(q);
    if (remote != null) {
      try {
        return await useCandidate(album, remote);
      } on Exception {
        // fall through to embedded art
      }
    }
    // 2. embedded picture of any track (yt-dlp thumbnails end up here)
    final tracks = await repo.tracks(albumId: album.id, limit: 20);
    for (final t in tracks) {
      if (!t.hasEmbeddedArt) continue;
      final f = await extractEmbedded(t);
      if (f == null) continue;
      final dest = _albumFile(album.id)..parent.createSync(recursive: true);
      await f.copy(dest.path);
      await repo.updateAlbum(album.id, coverPath: dest.path, coverSource: 'embedded');
      return dest;
    }
    return null;
  }

  /// Extracts the picture embedded in [t] (cropped to a square) into the cache.
  Future<File?> extractEmbedded(Track t) async {
    final f = _trackFile(t.id);
    if (f.existsSync()) return f;
    f.parent.createSync(recursive: true);
    final raw = File('${f.path}.raw');
    try {
      final ok = await bridges.tags.extractArt(path: t.hasRealPath ? t.filePath : null, uri: t.contentUri, out: raw.path);
      if (!ok) return null;
      final jpg = await _process(await raw.readAsBytes());
      await f.writeAsBytes(jpg, flush: true);
      return f;
    } on Exception {
      return null;
    } finally {
      if (raw.existsSync()) raw.deleteSync();
    }
  }

  /// yt-dlp embeds the 16:9 video thumbnail. Replace it (in the file) with a square crop so
  /// every player shows a proper album cover. Returns true when the file was rewritten.
  Future<bool> normalizeEmbedded(Track t) async {
    if (!t.hasEmbeddedArt || !settings.writeTagsToFiles) return false;
    final raw = File('${coversDir().path}/norm_${t.id}.raw')..parent.createSync(recursive: true);
    try {
      final ok = await bridges.tags.extractArt(path: t.hasRealPath ? t.filePath : null, uri: t.contentUri, out: raw.path);
      if (!ok) return false;
      final bytes = await raw.readAsBytes();
      final d = ImageProcessing.dimensions(bytes);
      if (d == null || (d.width == d.height && d.width <= ImageProcessing.maxEmbedSize)) return false;
      final jpg = await _process(bytes);
      final f = _trackFile(t.id);
      await f.writeAsBytes(jpg, flush: true);
      final outcome = await tagWriter.write(t, TagUpdate()..artPath = f.path);
      return outcome == TagWriteOutcome.written;
    } on Exception {
      return false;
    } finally {
      if (raw.existsSync()) raw.deleteSync();
    }
  }

  /// YouTube serves WebP thumbnails from /vi_webp/; the JPEG twin is friendlier to every decoder.
  static String preferJpegThumbnail(String url) =>
      url.replaceFirst('/vi_webp/', '/vi/').replaceFirst(RegExp(r'\.webp(\?.*)?$'), '.jpg');

  /// Uses a video thumbnail (yt-dlp info) as the track's cover: download, centre-crop to a
  /// square, embed into the file and remember it as the track's/album's cover.
  Future<File?> useThumbnail(Track t, String url) async {
    try {
      final bytes = Uint8List.fromList(await http.getBytes(preferJpegThumbnail(url)));
      final jpg = await _process(bytes);
      final f = _trackFile(t.id)..parent.createSync(recursive: true);
      await f.writeAsBytes(jpg, flush: true);
      if (settings.writeTagsToFiles) {
        final outcome = await tagWriter.write(t, TagUpdate()..artPath = f.path);
        if (outcome == TagWriteOutcome.written) await repo.updateTrackColumns(t.id, {'has_embedded_art': 1});
      }
      if (t.albumId != null) {
        final a = await repo.albumById(t.albumId!);
        if (a != null && cachedAlbumCover(a) == null) {
          final dest = _albumFile(a.id);
          await f.copy(dest.path);
          await repo.updateAlbum(a.id, coverPath: dest.path, coverSource: 'thumbnail');
        }
      }
      return f;
    } on Object {
      return null;
    }
  }

  /// Cover for a single track: its album cover, else embedded art.
  Future<File?> coverForTrack(Track t) async {
    if (t.albumId != null) {
      final a = await repo.albumById(t.albumId!);
      if (a != null) {
        final c = cachedAlbumCover(a);
        if (c != null) return c;
      }
    }
    if (t.hasEmbeddedArt) return extractEmbedded(t);
    return null;
  }

  // -------------------------------------------------------- ArtworkResolver

  @override
  Future<Uri?> artFor(MediaItem item) async {
    final thumb = item.extras?[MediaExtras.thumbnail] as String?;
    final id = item.trackId;
    if (id == null) return thumb == null ? item.artUri : Uri.tryParse(thumb);
    final t = await repo.trackById(id);
    if (t == null) return null;
    final f = await coverForTrack(t);
    return f == null ? null : Uri.file(f.path);
  }

  // ----------------------------------------------------------- manual + embed

  /// User picked an image from the gallery.
  Future<File> setManual(Album album, Uint8List imageBytes) async {
    final jpg = await _process(imageBytes);
    final f = _albumFile(album.id)..parent.createSync(recursive: true);
    await f.writeAsBytes(jpg, flush: true);
    await repo.updateAlbum(album.id, coverPath: f.path, coverSource: 'manual');
    return f;
  }

  /// Embeds the album cover into [t]'s file (<= 1200 px JPEG) and optionally saves cover.jpg.
  Future<TagWriteOutcome?> embedInto(Track t, File cover) async {
    if (!settings.writeTagsToFiles) return null;
    final update = TagUpdate()..artPath = cover.path;
    final outcome = await tagWriter.write(t, update);
    if (outcome == TagWriteOutcome.written) {
      await repo.updateTrackColumns(t.id, {'has_embedded_art': 1});
    }
    if (settings.saveCoverJpg && t.hasRealPath) {
      try {
        final dir = File(t.filePath).parent;
        final target = File('${dir.path}/cover.jpg');
        if (!target.existsSync()) await cover.copy(target.path);
      } on FileSystemException {
        // scoped storage: not allowed to create files next to media - best effort only
      }
    }
    return outcome;
  }
}
