import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/library/library_repository.dart';
import '../features/cover/cover_service.dart';

/// In-memory index of cover / artist image paths so long lists can resolve artwork
/// synchronously, plus a background queue that fetches covers for albums without one.
class CoverCache extends ChangeNotifier {
  CoverCache({required this.repo, required this.covers, this.autoFetch = true}) {
    _sub = repo.appDb.changes.listen((_) => _scheduleReload());
    _reload();
  }

  final LibraryRepository repo;
  final CoverService covers;
  final bool autoFetch;

  final Map<int, String> _albumCovers = {};
  final Map<int, String> _artistImages = {};
  final Set<int> _tried = {};
  final List<int> _pending = [];
  StreamSubscription<void>? _sub;
  Timer? _debounce;
  bool _fetching = false;
  bool _disposed = false;

  String? albumCover(int? albumId) => albumId == null ? null : _albumCovers[albumId];
  String? artistImage(int? artistId) => artistId == null ? null : _artistImages[artistId];

  void _scheduleReload() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _reload);
  }

  Future<void> _reload() async {
    if (_disposed) return;
    final albums = await repo.albums();
    final artists = await repo.artists();
    if (_disposed) return;
    var changed = false;
    final aSeen = <int>{};
    for (final a in albums) {
      aSeen.add(a.id);
      final p = a.coverPath;
      if (p != null && File(p).existsSync()) {
        if (_albumCovers[a.id] != p) {
          _albumCovers[a.id] = p;
          changed = true;
        }
      } else {
        if (_albumCovers.remove(a.id) != null) changed = true;
        if (autoFetch && !_tried.contains(a.id) && !_pending.contains(a.id)) _pending.add(a.id);
      }
    }
    if (_albumCovers.keys.any((k) => !aSeen.contains(k))) {
      _albumCovers.removeWhere((k, _) => !aSeen.contains(k));
      changed = true;
    }
    for (final r in artists) {
      final p = r.imagePath;
      if (p != null && File(p).existsSync() && _artistImages[r.id] != p) {
        _artistImages[r.id] = p;
        changed = true;
      }
    }
    if (changed) notifyListeners();
    _drain();
  }

  /// Fetch covers one at a time; each provider is rate limited anyway.
  Future<void> _drain() async {
    if (_fetching || _disposed) return;
    _fetching = true;
    try {
      while (_pending.isNotEmpty && !_disposed) {
        final id = _pending.removeAt(0);
        _tried.add(id);
        try {
          final album = await repo.albumById(id);
          if (album == null) continue;
          final f = await covers.ensureAlbumCover(album);
          if (f != null && !_disposed) {
            _albumCovers[id] = f.path;
            notifyListeners();
          }
        } on Object {
          // offline or provider trouble: the album stays on the placeholder
        }
      }
    } finally {
      _fetching = false;
    }
  }

  /// Let a failed album try again (after the user edits tags, for instance).
  void retry(int albumId) {
    _tried.remove(albumId);
    _scheduleReload();
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _sub?.cancel();
    super.dispose();
  }
}
