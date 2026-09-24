import '../../core/library/library_repository.dart';
import '../../core/models/track.dart';
import '../../platform/bridges.dart';

enum TagWriteOutcome {
  /// Tags are in the file (and the database).
  written,

  /// The user declined Android's write-access dialog; database only.
  permissionDenied,

  /// Container that jaudiotagger cannot write (Opus); database only.
  unsupported,

  /// Something else went wrong; database only.
  failed,
}

/// Writes tags into audio files and keeps the database in step.
///
/// Files this app created (downloads) are writable directly. Files it did not create
/// need one-time approval through MediaStore.createWriteRequest on Android 11+.
class TagWriter {
  TagWriter({required this.repo, required this.bridges});

  final LibraryRepository repo;
  final Bridges bridges;

  bool _askedThisSession = false;

  Future<TagWriteOutcome> write(Track t, TagUpdate update) async {
    if (update.isEmpty) return TagWriteOutcome.written;
    Future<FileStat2> attempt() => bridges.tags.write(
          path: t.hasRealPath ? t.filePath : null,
          uri: t.contentUri,
          update: update,
        );
    try {
      FileStat2 stat;
      try {
        stat = await attempt();
      } on PlatformFailure catch (e) {
        if (!e.needsPermission || t.contentUri == null || !t.contentUri!.startsWith('content://media')) rethrow;
        // Ask once per app run; a "no" is remembered so a batch job does not nag repeatedly.
        if (_askedThisSession) return TagWriteOutcome.permissionDenied;
        final granted = await bridges.mediaStore.requestWrite([t.contentUri!]);
        _askedThisSession = !granted;
        if (!granted) return TagWriteOutcome.permissionDenied;
        stat = await attempt();
      }
      // Remember the new size/mtime so the next scan does not re-read the file.
      await repo.updateTrackColumns(t.id, {
        if (stat.size > 0) 'size_bytes': stat.size,
        if (stat.lastModified > 0) 'file_mtime': stat.lastModified,
      });
      return TagWriteOutcome.written;
    } on PlatformFailure catch (e) {
      if (e.unsupportedFormat) return TagWriteOutcome.unsupported;
      if (e.needsPermission) return TagWriteOutcome.permissionDenied;
      return TagWriteOutcome.failed;
    }
  }

  /// Writes the same [update] into many files, asking Android for write access once for the
  /// whole batch instead of once per file (an album edit touches a dozen files).
  /// Returns the outcome per track id.
  Future<Map<int, TagWriteOutcome>> writeAll(List<Track> tracks, TagUpdate update) async {
    final out = <int, TagWriteOutcome>{};
    if (update.isEmpty) return {for (final t in tracks) t.id: TagWriteOutcome.written};

    Future<TagWriteOutcome?> attempt(Track t) async {
      try {
        final stat = await bridges.tags.write(path: t.hasRealPath ? t.filePath : null, uri: t.contentUri, update: update);
        await repo.updateTrackColumns(t.id, {
          if (stat.size > 0) 'size_bytes': stat.size,
          if (stat.lastModified > 0) 'file_mtime': stat.lastModified,
        });
        return TagWriteOutcome.written;
      } on PlatformFailure catch (e) {
        if (e.unsupportedFormat) return TagWriteOutcome.unsupported;
        if (e.needsPermission) {
          // Only MediaStore files can be unlocked through the system dialog.
          return t.contentUri != null && t.contentUri!.startsWith('content://media') ? null : TagWriteOutcome.permissionDenied;
        }
        return TagWriteOutcome.failed;
      }
    }

    final locked = <Track>[];
    for (final t in tracks) {
      final r = await attempt(t);
      if (r == null) {
        locked.add(t);
      } else {
        out[t.id] = r;
      }
    }
    if (locked.isNotEmpty) {
      // A person asked for this edit, so ask again even if an earlier background write was refused.
      final granted = await bridges.mediaStore.requestWrite([for (final t in locked) t.contentUri!]);
      if (!granted) {
        for (final t in locked) {
          out[t.id] = TagWriteOutcome.permissionDenied;
        }
      } else {
        for (final t in locked) {
          out[t.id] = await attempt(t) ?? TagWriteOutcome.permissionDenied;
        }
      }
    }
    return out;
  }
}
