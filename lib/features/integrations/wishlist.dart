import '../../core/db/app_database.dart';
import '../../core/models/library_models.dart';
import 'metadata_clients.dart';

/// Songs we want but do not have (imported playlists, suggestions from radio).
class WishlistRepository {
  WishlistRepository(this.appDb);

  final AppDatabase appDb;

  int get _now => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  Future<int> add(WishTrack t, {String? origin}) async {
    final existing = await appDb.db.query(
      'wishlist',
      columns: ['id'],
      where: 'artist = ? COLLATE NOCASE AND title = ? COLLATE NOCASE AND status != ?',
      whereArgs: [t.artist, t.title, 'done'],
      limit: 1,
    );
    if (existing.isNotEmpty) return existing.first['id'] as int;
    final id = await appDb.db.insert('wishlist', {
      'artist': t.artist,
      'title': t.title,
      'album': t.album,
      'isrc': t.isrc,
      'origin': origin,
      'status': 'pending',
      'created_at': _now,
    });
    appDb.notifyChanged();
    return id;
  }

  Future<List<WishlistItem>> all({String? status}) async {
    final rows = await appDb.db.query(
      'wishlist',
      where: status == null ? null : 'status = ?',
      whereArgs: status == null ? null : [status],
      orderBy: 'created_at DESC, id DESC',
    );
    return rows.map(WishlistItem.fromMap).toList();
  }

  Future<void> setStatus(int id, String status, {int? jobId}) async {
    await appDb.db.update('wishlist', {'status': status, if (jobId != null) 'job_id': jobId}, where: 'id = ?', whereArgs: [id]);
    appDb.notifyChanged();
  }

  Future<void> remove(int id) async {
    await appDb.db.delete('wishlist', where: 'id = ?', whereArgs: [id]);
    appDb.notifyChanged();
  }

  Stream<List<WishlistItem>> watch() => appDb.watch(() => all());
}
