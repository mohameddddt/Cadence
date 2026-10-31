import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../db/app_database.dart';
import '../models/library_models.dart';
import '../models/track.dart';
import 'album_grouping.dart';
import 'smart_rules.dart';

/// Row cached from the last scan so unchanged files are skipped.
class ScanIndexEntry {
  const ScanIndexEntry(this.id, this.mtime, this.size, this.source);
  final int id;
  final int mtime;
  final int size;
  final String source;
}

/// The library DAO: tracks, albums, artists, playlists, lyrics, play statistics.
///
/// All reads return plain model objects; all writes call [AppDatabase.notifyChanged]
/// so `watch*` streams refresh.
class LibraryRepository {
  LibraryRepository(this.appDb);

  final AppDatabase appDb;
  Database get db => appDb.db;

  int get _now => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  // ------------------------------------------------------------------ tracks

  Future<Track?> trackById(int id) async {
    final rows = await db.query('tracks', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Track.fromMap(rows.first);
  }

  Future<List<Track>> tracksByIds(Iterable<int> ids) async {
    final list = ids.toList();
    if (list.isEmpty) return [];
    final byId = <int, Track>{};
    for (var i = 0; i < list.length; i += 500) {
      final chunk = list.sublist(i, i + 500 > list.length ? list.length : i + 500);
      final rows = await db.query('tracks', where: 'id IN (${List.filled(chunk.length, '?').join(',')})', whereArgs: chunk);
      for (final r in rows) {
        final t = Track.fromMap(r);
        byId[t.id] = t;
      }
    }
    return [for (final id in list) if (byId[id] != null) byId[id]!];
  }

  Future<Track?> trackByPath(String path) async {
    final rows = await db.query('tracks', where: 'file_path = ?', whereArgs: [path], limit: 1);
    return rows.isEmpty ? null : Track.fromMap(rows.first);
  }

  Future<Track?> trackBySourceUrl(String url) async {
    final rows = await db.query('tracks', where: 'source_url = ? AND missing = 0', whereArgs: [url], limit: 1);
    return rows.isEmpty ? null : Track.fromMap(rows.first);
  }

  Future<Track?> trackByRecording(String mbid) async {
    final rows = await db.query('tracks', where: 'mb_recording_id = ? AND missing = 0', whereArgs: [mbid], limit: 1);
    return rows.isEmpty ? null : Track.fromMap(rows.first);
  }

  Future<Track?> trackByHash(String hash) async {
    final rows = await db.query('tracks', where: 'audio_hash = ? AND missing = 0', whereArgs: [hash], limit: 1);
    return rows.isEmpty ? null : Track.fromMap(rows.first);
  }

  /// Returns the first existing track that duplicates the given identity, if any.
  /// Checks source URL, MusicBrainz recording and content hash (pitfall #8).
  Future<Track?> findDuplicate({String? sourceUrl, String? mbRecordingId, String? audioHash}) async {
    if (sourceUrl != null && sourceUrl.isNotEmpty) {
      final t = await trackBySourceUrl(sourceUrl);
      if (t != null) return t;
    }
    if (mbRecordingId != null && mbRecordingId.isNotEmpty) {
      final t = await trackByRecording(mbRecordingId);
      if (t != null) return t;
    }
    if (audioHash != null && audioHash.isNotEmpty) {
      final t = await trackByHash(audioHash);
      if (t != null) return t;
    }
    return null;
  }

  Future<List<Track>> tracks({
    TrackSort sort = TrackSort.title,
    bool descending = false,
    int? albumId,
    int? artistId,
    String? genre,
    String? folder,
    String? source,
    bool? identified,
    int? limit,
    int? offset,
  }) async {
    final where = <String>['t.missing = 0'];
    final args = <Object?>[];
    if (albumId != null) {
      where.add('t.album_id = ?');
      args.add(albumId);
    }
    if (artistId != null) {
      where.add('t.artist_id = ?');
      args.add(artistId);
    }
    if (genre != null) {
      where.add('t.genre = ? COLLATE NOCASE');
      args.add(genre);
    }
    if (folder != null) {
      where.add('t.folder = ?');
      args.add(folder);
    }
    if (source != null) {
      where.add('t.source = ?');
      args.add(source);
    }
    if (identified != null) {
      where.add(identified ? "t.mb_recording_id IS NOT NULL AND t.mb_recording_id != ''" : "(t.mb_recording_id IS NULL OR t.mb_recording_id = '')");
    }
    final dir = sort == TrackSort.random ? '' : (descending ? ' DESC' : ' ASC');
    final rows = await db.rawQuery(
      'SELECT t.* FROM tracks t WHERE ${where.join(' AND ')} ORDER BY ${sort.sql}$dir'
      '${limit != null ? ' LIMIT $limit' : ''}${offset != null ? ' OFFSET $offset' : ''}',
      args,
    );
    return rows.map(Track.fromMap).toList();
  }

  Future<List<Track>> tracksWithAlbumArtist(String name) async {
    final rows = await db.rawQuery('SELECT * FROM tracks WHERE missing = 0 AND album_artist = ? COLLATE NOCASE', [name]);
    return rows.map(Track.fromMap).toList();
  }

  Future<int> trackCount() async =>
      Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM tracks WHERE missing = 0')) ?? 0;

  Future<List<Track>> recentlyPlayed({int limit = 20}) async {
    final rows = await db.rawQuery(
      'SELECT * FROM tracks WHERE missing = 0 AND last_played IS NOT NULL ORDER BY last_played DESC LIMIT ?',
      [limit],
    );
    return rows.map(Track.fromMap).toList();
  }

  Future<List<Track>> recentlyAdded({int limit = 20}) async {
    final rows = await db.rawQuery(
      'SELECT * FROM tracks WHERE missing = 0 ORDER BY date_added DESC, id DESC LIMIT ?',
      [limit],
    );
    return rows.map(Track.fromMap).toList();
  }

  Future<List<Track>> mostPlayed({int limit = 20}) async {
    final rows = await db.rawQuery(
      'SELECT * FROM tracks WHERE missing = 0 AND play_count > 0 ORDER BY play_count DESC, last_played DESC LIMIT ?',
      [limit],
    );
    return rows.map(Track.fromMap).toList();
  }

  Future<List<Track>> lovedTracks() async {
    final rows = await db.rawQuery('SELECT * FROM tracks WHERE missing = 0 AND loved = 1 ORDER BY title COLLATE NOCASE');
    return rows.map(Track.fromMap).toList();
  }

  /// Tracks whose identification is still pending (never matched, not skipped).
  Future<List<Track>> unidentified({int? limit}) async {
    final rows = await db.rawQuery(
      'SELECT * FROM tracks WHERE missing = 0 AND identify_state IN (0, 2) '
      "AND (mb_recording_id IS NULL OR mb_recording_id = '') ORDER BY identify_state DESC, date_added DESC"
      '${limit != null ? ' LIMIT $limit' : ''}',
    );
    return rows.map(Track.fromMap).toList();
  }

  // ------------------------------------------------------------- scanning I/O

  /// path -> (id, mtime, size) for every known non-missing track.
  Future<Map<String, ScanIndexEntry>> scanIndex() async {
    final rows = await db.rawQuery('SELECT id, file_path, file_mtime, size_bytes, source FROM tracks');
    return {
      for (final r in rows)
        r['file_path'] as String: ScanIndexEntry(
          r['id'] as int,
          (r['file_mtime'] as int?) ?? 0,
          (r['size_bytes'] as int?) ?? 0,
          (r['source'] as String?) ?? 'local',
        ),
    };
  }

  /// Inserts or updates one track (matched by file path) and (re)links its artist and
  /// album rows. Play statistics, rating and lyrics of an existing row are preserved.
  Future<int> upsertTrack(TrackDraft d, {bool notify = true}) async {
    final id = await db.transaction((txn) => _upsert(txn, d));
    if (notify) appDb.notifyChanged();
    return id;
  }

  Future<void> upsertTracks(Iterable<TrackDraft> drafts) async {
    await db.transaction((txn) async {
      for (final d in drafts) {
        await _upsert(txn, d);
      }
    });
    appDb.notifyChanged();
  }

  Future<int> _upsert(DatabaseExecutor txn, TrackDraft d) async {
    final artistName = _clean(d.artist);
    final artistId = artistName == null ? null : await _artistId(txn, artistName, mbid: d.mbArtistId);
    final albumTitle = _clean(d.album);
    final albumArtist = _clean(d.albumArtist);
    final groupKey = albumGroupKey(
      album: albumTitle,
      albumArtist: albumArtist,
      folder: d.folder,
      mbReleaseId: d.mbReleaseId,
    );
    final existing = await txn.query('tracks', columns: ['id', 'album_id'], where: 'file_path = ?', whereArgs: [d.filePath], limit: 1);
    final oldAlbumId = existing.isEmpty ? null : existing.first['album_id'] as int?;

    int? albumId;
    if (groupKey != null) {
      albumId = await _albumId(
        txn,
        groupKey: groupKey,
        title: albumTitle!,
        mbReleaseId: d.mbReleaseId,
        mbReleaseGroupId: d.mbReleaseGroupId,
      );
    }

    final values = <String, Object?>{
      'file_path': d.filePath,
      'content_uri': d.contentUri,
      'folder': d.folder,
      'title': d.title.trim().isEmpty ? 'Untitled' : d.title.trim(),
      'artist_id': artistId,
      'artist_name': artistName,
      'album_artist': albumArtist,
      'album_id': albumId,
      'album_title': albumTitle,
      'track_no': d.trackNo,
      'disc_no': d.discNo,
      'duration_ms': d.durationMs,
      'year': d.year,
      'genre': _clean(d.genre),
      'bitrate': d.bitrate,
      'format': d.format,
      'size_bytes': d.sizeBytes,
      'file_mtime': d.fileMtime,
      'source': d.source.name,
      'source_url': d.sourceUrl,
      'mb_recording_id': d.mbRecordingId,
      'mb_release_id': d.mbReleaseId,
      'mb_release_group_id': d.mbReleaseGroupId,
      'mb_artist_id': d.mbArtistId,
      'acoustid': d.acoustId,
      'isrc': d.isrc,
      'replay_gain_track': d.replayGainTrack,
      'replay_gain_album': d.replayGainAlbum,
      'audio_hash': d.audioHash,
      'has_embedded_art': d.hasEmbeddedArt ? 1 : 0,
      'missing': 0,
    };
    if (d.identifyState != null) {
      values['identify_state'] = d.identifyState;
    } else if (d.mbRecordingId != null && d.mbRecordingId!.isNotEmpty) {
      values['identify_state'] = IdentifyState.matched;
    }

    int id;
    if (existing.isEmpty) {
      values['date_added'] = d.dateAdded ?? _now;
      id = await txn.insert('tracks', values);
    } else {
      id = existing.first['id'] as int;
      // Preserve values we might not know when re-reading (e.g. audio hash of a file
      // we hashed at download time).
      if (d.audioHash == null) values.remove('audio_hash');
      if (d.sourceUrl == null) values.remove('source_url');
      if (d.source == TrackSource.local) values.remove('source');
      await txn.update('tracks', values, where: 'id = ?', whereArgs: [id]);
    }
    if (albumId != null) await _refreshAlbum(txn, albumId);
    if (oldAlbumId != null && oldAlbumId != albumId) await _refreshAlbum(txn, oldAlbumId);
    return id;
  }

  String? _clean(String? s) {
    final t = s?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }

  Future<int> _artistId(DatabaseExecutor txn, String name, {String? mbid}) async {
    if (mbid != null && mbid.isNotEmpty) {
      final byMb = await txn.query('artists', columns: ['id'], where: 'mb_artist_id = ?', whereArgs: [mbid], limit: 1);
      if (byMb.isNotEmpty) return byMb.first['id'] as int;
    }
    final byName = await txn.query('artists', columns: ['id', 'mb_artist_id'], where: 'name = ? COLLATE NOCASE', whereArgs: [name], limit: 1);
    if (byName.isNotEmpty) {
      final id = byName.first['id'] as int;
      if (mbid != null && mbid.isNotEmpty && byName.first['mb_artist_id'] == null) {
        await txn.update('artists', {'mb_artist_id': mbid}, where: 'id = ?', whereArgs: [id]);
      }
      return id;
    }
    return txn.insert('artists', {'name': name, 'sort_name': sortName(name), 'mb_artist_id': mbid});
  }

  /// "The Beatles" -> "Beatles, The"; keeps everything else as is.
  static String sortName(String name) {
    final m = RegExp(r'^(the|a|an)\s+(.+)$', caseSensitive: false).firstMatch(name);
    return m == null ? name : '${m.group(2)}, ${m.group(1)}';
  }

  Future<int> _albumId(
    DatabaseExecutor txn, {
    required String groupKey,
    required String title,
    String? mbReleaseId,
    String? mbReleaseGroupId,
  }) async {
    final rows = await txn.query('albums', columns: ['id'], where: 'group_key = ?', whereArgs: [groupKey], limit: 1);
    if (rows.isNotEmpty) return rows.first['id'] as int;
    return txn.insert('albums', {
      'group_key': groupKey,
      'title': title,
      'mb_release_id': mbReleaseId,
      'mb_release_group_id': mbReleaseGroupId,
    });
  }

  /// Recomputes derived album fields (artist, year, MBIDs) or removes an empty album.
  Future<void> _refreshAlbum(DatabaseExecutor txn, int albumId) async {
    final tracks = await txn.query(
      'tracks',
      columns: ['artist_name', 'album_artist', 'year', 'mb_release_id', 'mb_release_group_id'],
      where: 'album_id = ? AND missing = 0',
      whereArgs: [albumId],
    );
    if (tracks.isEmpty) {
      final any = await txn.query('tracks', columns: ['id'], where: 'album_id = ?', whereArgs: [albumId], limit: 1);
      if (any.isEmpty) await txn.delete('albums', where: 'id = ?', whereArgs: [albumId]);
      return;
    }
    String? aaTag;
    int? year;
    String? mbRelease;
    String? mbGroup;
    for (final t in tracks) {
      aaTag ??= _clean(t['album_artist'] as String?);
      final y = t['year'] as int?;
      if (y != null && y > 0 && (year == null || y < year)) year = y;
      mbRelease ??= _clean(t['mb_release_id'] as String?);
      mbGroup ??= _clean(t['mb_release_group_id'] as String?);
    }
    final artistName = resolveAlbumArtist(
      albumArtistTag: aaTag,
      trackArtists: tracks.map((t) => t['artist_name'] as String?),
    );
    int? artistId;
    if (artistName != null && !isVariousArtists(artistName)) {
      artistId = await _artistId(txn, artistName);
    }
    await txn.update(
      'albums',
      {
        'artist_name': artistName,
        'artist_id': artistId,
        'year': year,
        'compilation': (artistName != null && isVariousArtists(artistName)) ? 1 : 0,
        if (mbRelease != null) 'mb_release_id': mbRelease,
        if (mbGroup != null) 'mb_release_group_id': mbGroup,
      },
      where: 'id = ?',
      whereArgs: [albumId],
    );
  }

  /// Removes rows whose backing file disappeared and cleans up orphan albums/artists.
  Future<int> deleteTracks(Iterable<int> ids) async {
    final list = ids.toList();
    if (list.isEmpty) return 0;
    var removed = 0;
    await db.transaction((txn) async {
      final albums = <int>{};
      for (var i = 0; i < list.length; i += 500) {
        final chunk = list.sublist(i, i + 500 > list.length ? list.length : i + 500);
        final ph = List.filled(chunk.length, '?').join(',');
        final rows = await txn.rawQuery('SELECT DISTINCT album_id FROM tracks WHERE id IN ($ph) AND album_id IS NOT NULL', chunk);
        albums.addAll(rows.map((r) => r['album_id'] as int));
        removed += await txn.delete('tracks', where: 'id IN ($ph)', whereArgs: chunk);
      }
      for (final a in albums) {
        await _refreshAlbum(txn, a);
      }
      await _deleteOrphanArtists(txn);
    });
    appDb.notifyChanged();
    return removed;
  }

  Future<void> updateTrackColumns(int id, Map<String, Object?> values) async {
    if (values.isEmpty) return;
    await db.update('tracks', values, where: 'id = ?', whereArgs: [id]);
    appDb.notifyChanged();
  }

  /// Re-links artist/album for an already known track after its tags changed
  /// (used by the tag editor and identification).
  Future<void> applyTagChanges(int id, TrackDraft draft) async {
    final t = await trackById(id);
    if (t == null) return;
    draft.filePath = t.filePath;
    draft.contentUri ??= t.contentUri;
    draft.folder ??= t.folder;
    draft.sizeBytes = draft.sizeBytes == 0 ? t.sizeBytes : draft.sizeBytes;
    draft.fileMtime = draft.fileMtime == 0 ? t.fileMtime : draft.fileMtime;
    draft.source = t.source;
    draft.sourceUrl ??= t.sourceUrl;
    draft.audioHash ??= t.audioHash;
    await upsertTrack(draft);
  }

  // ------------------------------------------------------------ albums/artists

  static const String _albumSelect =
      'SELECT a.*, (SELECT COUNT(*) FROM tracks t WHERE t.album_id = a.id AND t.missing = 0) AS track_count, '
      '(SELECT COALESCE(SUM(t.duration_ms), 0) FROM tracks t WHERE t.album_id = a.id AND t.missing = 0) AS total_duration '
      'FROM albums a';

  Future<List<Album>> albums({int? artistId, String? query, String orderBy = 'a.title COLLATE NOCASE'}) async {
    final where = <String>[];
    final args = <Object?>[];
    if (artistId != null) {
      where.add('(a.artist_id = ? OR a.id IN (SELECT album_id FROM tracks WHERE artist_id = ? AND album_id IS NOT NULL))');
      args..add(artistId)..add(artistId);
    }
    if (query != null && query.trim().isNotEmpty) {
      where.add("(a.title LIKE ? ESCAPE '\\' OR a.artist_name LIKE ? ESCAPE '\\')");
      final q = '%${_escapeLike(query.trim())}%';
      args..add(q)..add(q);
    }
    final rows = await db.rawQuery(
      '$_albumSelect ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'} ORDER BY $orderBy',
      args,
    );
    return rows.map(Album.fromMap).where((a) => a.trackCount > 0).toList();
  }

  Future<Album?> albumById(int id) async {
    final rows = await db.rawQuery('$_albumSelect WHERE a.id = ?', [id]);
    return rows.isEmpty ? null : Album.fromMap(rows.first);
  }

  Future<void> updateAlbum(int id, {String? coverPath, String? coverSource, String? mbReleaseId, String? mbReleaseGroupId}) async {
    final v = <String, Object?>{
      if (coverPath != null) 'cover_path': coverPath,
      if (coverSource != null) 'cover_source': coverSource,
      if (mbReleaseId != null) 'mb_release_id': mbReleaseId,
      if (mbReleaseGroupId != null) 'mb_release_group_id': mbReleaseGroupId,
    };
    if (v.isEmpty) return;
    await db.update('albums', v, where: 'id = ?', whereArgs: [id]);
    appDb.notifyChanged();
  }

  static const String _artistSelect =
      'SELECT r.*, (SELECT COUNT(*) FROM tracks t WHERE t.artist_id = r.id AND t.missing = 0) AS track_count, '
      '(SELECT COUNT(DISTINCT t.album_id) FROM tracks t WHERE t.artist_id = r.id AND t.missing = 0 AND t.album_id IS NOT NULL) AS album_count '
      'FROM artists r';

  Future<List<Artist>> artists({String? query, bool followedOnly = false}) async {
    final where = <String>[];
    final args = <Object?>[];
    if (query != null && query.trim().isNotEmpty) {
      where.add("r.name LIKE ? ESCAPE '\\'");
      args.add('%${_escapeLike(query.trim())}%');
    }
    if (followedOnly) where.add('r.followed = 1');
    final rows = await db.rawQuery(
      '$_artistSelect ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'} ORDER BY COALESCE(r.sort_name, r.name) COLLATE NOCASE',
      args,
    );
    return rows.map(Artist.fromMap).where((a) => a.trackCount > 0 || a.followed).toList();
  }

  Future<Artist?> artistById(int id) async {
    final rows = await db.rawQuery('$_artistSelect WHERE r.id = ?', [id]);
    return rows.isEmpty ? null : Artist.fromMap(rows.first);
  }

  Future<Artist?> artistByName(String name) async {
    final rows = await db.rawQuery('$_artistSelect WHERE r.name = ? COLLATE NOCASE', [name]);
    return rows.isEmpty ? null : Artist.fromMap(rows.first);
  }

  Future<void> updateArtist(
    int id, {
    String? mbArtistId,
    String? imagePath,
    String? imageUrl,
    String? bio,
    String? bioSource,
    bool? followed,
    int? lastReleaseCheck,
    bool touchInfo = false,
  }) async {
    final v = <String, Object?>{
      if (mbArtistId != null) 'mb_artist_id': mbArtistId,
      if (imagePath != null) 'image_path': imagePath,
      if (imageUrl != null) 'image_url': imageUrl,
      if (bio != null) 'bio': bio,
      if (bioSource != null) 'bio_source': bioSource,
      if (followed != null) 'followed': followed ? 1 : 0,
      if (lastReleaseCheck != null) 'last_release_check': lastReleaseCheck,
      if (touchInfo) 'info_fetched_at': _now,
    };
    if (v.isEmpty) return;
    await db.update('artists', v, where: 'id = ?', whereArgs: [id]);
    appDb.notifyChanged();
  }

  // ---------------------------------------------------------- library management
  //
  // Edits made from the dashboard. They change the track rows (the source of truth the
  // scanner rebuilds albums and artists from) and then re-derive the album/artist rows, so a
  // later incremental scan does not undo them. The file tags are written by LibraryEditor.

  Future<LibraryStats> stats() async {
    final r = (await db.rawQuery(
      'SELECT COUNT(*) AS n, COUNT(DISTINCT album_id) AS albums, COUNT(DISTINCT artist_id) AS artists, '
      'COALESCE(SUM(duration_ms), 0) AS dur, COALESCE(SUM(size_bytes), 0) AS bytes, '
      "COALESCE(SUM(CASE WHEN mb_recording_id IS NOT NULL AND mb_recording_id != '' THEN 1 ELSE 0 END), 0) AS idn, "
      'COALESCE(SUM(loved), 0) AS loved FROM tracks WHERE missing = 0',
    ))
        .first;
    return LibraryStats(
      tracks: r['n'] as int,
      albums: r['albums'] as int,
      artists: r['artists'] as int,
      durationMs: (r['dur'] as num).toInt(),
      sizeBytes: (r['bytes'] as num).toInt(),
      identified: (r['idn'] as num).toInt(),
      loved: (r['loved'] as num).toInt(),
    );
  }

  Future<List<({int id, String name, int count})>> topArtists({int limit = 5}) async {
    final rows = await db.rawQuery(
      'SELECT r.id AS id, r.name AS name, COUNT(*) AS n FROM tracks t JOIN artists r ON r.id = t.artist_id '
      'WHERE t.missing = 0 GROUP BY r.id ORDER BY n DESC, r.name COLLATE NOCASE LIMIT ?',
      [limit],
    );
    return [for (final r in rows) (id: r['id'] as int, name: r['name'] as String, count: r['n'] as int)];
  }

  Future<void> _deleteOrphanArtists(DatabaseExecutor txn) => txn.rawDelete(
        'DELETE FROM artists WHERE id NOT IN (SELECT artist_id FROM tracks WHERE artist_id IS NOT NULL) '
        'AND id NOT IN (SELECT artist_id FROM albums WHERE artist_id IS NOT NULL) AND followed = 0',
      );

  /// Re-derives an album's group key from its tracks after the album title or album artist
  /// changed. Returns the id the tracks ended up in: a different one when they merged into an
  /// album that already had the new identity.
  Future<int> _regroupAlbum(DatabaseExecutor txn, int albumId) async {
    final albumRows = await txn.query('albums', where: 'id = ?', whereArgs: [albumId], limit: 1);
    if (albumRows.isEmpty) return albumId;
    final album = albumRows.first;
    final tracks = await txn.query('tracks', columns: ['folder', 'album_artist', 'mb_release_id'], where: 'album_id = ?', whereArgs: [albumId]);
    if (tracks.isEmpty) return albumId;
    String? albumArtist;
    String? mbRelease;
    for (final t in tracks) {
      albumArtist ??= _clean(t['album_artist'] as String?);
      mbRelease ??= _clean(t['mb_release_id'] as String?);
    }
    final key = albumGroupKey(
      album: album['title'] as String,
      albumArtist: albumArtist,
      folder: tracks.first['folder'] as String?,
      mbReleaseId: mbRelease,
    );
    if (key == null || key == album['group_key']) return albumId;
    final clash = await txn.query('albums', columns: ['id'], where: 'group_key = ? AND id != ?', whereArgs: [key, albumId], limit: 1);
    if (clash.isEmpty) {
      await txn.update('albums', {'group_key': key}, where: 'id = ?', whereArgs: [albumId]);
      return albumId;
    }
    final target = clash.first['id'] as int;
    await _absorbAlbum(txn, source: albumId, target: target);
    return target;
  }

  /// Moves every track of [source] into [target] and deletes [source]; the cover moves along
  /// when the target has none.
  Future<void> _absorbAlbum(DatabaseExecutor txn, {required int source, required int target}) async {
    await txn.update('tracks', {'album_id': target}, where: 'album_id = ?', whereArgs: [source]);
    final s = await txn.query('albums', where: 'id = ?', whereArgs: [source], limit: 1);
    final t = await txn.query('albums', where: 'id = ?', whereArgs: [target], limit: 1);
    if (s.isNotEmpty && t.isNotEmpty && t.first['cover_path'] == null && s.first['cover_path'] != null) {
      await txn.update('albums', {'cover_path': s.first['cover_path'], 'cover_source': s.first['cover_source']}, where: 'id = ?', whereArgs: [target]);
    }
    await txn.delete('albums', where: 'id = ?', whereArgs: [source]);
    await _refreshAlbum(txn, target);
  }

  /// Applies album-level edits to every track of the album. `null` leaves a field alone; an
  /// empty string clears a text field and a [year] of 0 clears the year. Returns the id of the
  /// resulting album (different from [albumId] if it merged into an existing one).
  Future<int> editAlbum(int albumId, {String? title, String? albumArtist, int? year, String? genre}) async {
    var result = albumId;
    await db.transaction((txn) async {
      final cleanTitle = _clean(title);
      final tv = <String, Object?>{
        if (cleanTitle != null) 'album_title': cleanTitle,
        if (albumArtist != null) 'album_artist': _clean(albumArtist),
        if (year != null) 'year': year <= 0 ? null : year,
        if (genre != null) 'genre': _clean(genre),
      };
      if (tv.isNotEmpty) await txn.update('tracks', tv, where: 'album_id = ?', whereArgs: [albumId]);
      if (cleanTitle != null) await txn.update('albums', {'title': cleanTitle}, where: 'id = ?', whereArgs: [albumId]);
      result = await _regroupAlbum(txn, albumId);
      await _refreshAlbum(txn, result);
      await _deleteOrphanArtists(txn);
    });
    appDb.notifyChanged();
    return result;
  }

  /// Folds [sourceId] into [targetId]: the source's tracks take the target's title, album artist
  /// and MusicBrainz ids. Returns the surviving album id ([targetId]).
  Future<int> mergeAlbums(int sourceId, int targetId) async {
    if (sourceId == targetId) return targetId;
    await db.transaction((txn) async {
      final t = await txn.query('albums', where: 'id = ?', whereArgs: [targetId], limit: 1);
      if (t.isEmpty) return;
      final target = t.first;
      final targetTracks = await txn.query('tracks', columns: ['album_artist'], where: 'album_id = ?', whereArgs: [targetId]);
      String? albumArtist;
      for (final r in targetTracks) {
        albumArtist ??= _clean(r['album_artist'] as String?);
      }
      await txn.update(
        'tracks',
        {
          'album_id': targetId,
          'album_title': target['title'],
          if (albumArtist != null) 'album_artist': albumArtist,
          if (_clean(target['mb_release_id'] as String?) != null) 'mb_release_id': target['mb_release_id'],
          if (_clean(target['mb_release_group_id'] as String?) != null) 'mb_release_group_id': target['mb_release_group_id'],
        },
        where: 'album_id = ?',
        whereArgs: [sourceId],
      );
      await _absorbAlbum(txn, source: sourceId, target: targetId);
      await _deleteOrphanArtists(txn);
    });
    appDb.notifyChanged();
    return targetId;
  }

  /// Renames an artist everywhere (tracks, album artists, group keys). If [newName] already
  /// belongs to another artist the two are merged. Returns the surviving artist id.
  Future<int> renameArtist(int artistId, String newName) async {
    final name = _clean(newName);
    if (name == null) throw ArgumentError('An artist needs a name');
    var result = artistId;
    await db.transaction((txn) async {
      final rows = await txn.query('artists', where: 'id = ?', whereArgs: [artistId], limit: 1);
      if (rows.isEmpty) return;
      final old = rows.first['name'] as String;
      final clash = await txn.query('artists', columns: ['id'], where: 'name = ? COLLATE NOCASE AND id != ?', whereArgs: [name, artistId], limit: 1);
      if (clash.isNotEmpty) {
        result = clash.first['id'] as int;
        await _mergeArtists(txn, artistId, result);
        return;
      }
      final touched = await _albumsOfArtist(txn, artistId, old);
      await txn.update('artists', {'name': name, 'sort_name': sortName(name)}, where: 'id = ?', whereArgs: [artistId]);
      await txn.update('tracks', {'artist_name': name}, where: 'artist_id = ?', whereArgs: [artistId]);
      await txn.update('tracks', {'album_artist': name}, where: 'album_artist = ? COLLATE NOCASE', whereArgs: [old]);
      await txn.update('albums', {'artist_name': name}, where: 'artist_id = ?', whereArgs: [artistId]);
      await _regroupAndRefresh(txn, touched);
    });
    appDb.notifyChanged();
    return result;
  }

  /// Folds [sourceId] into [targetId] (duplicate spellings of one artist).
  Future<int> mergeArtists(int sourceId, int targetId) async {
    if (sourceId == targetId) return targetId;
    await db.transaction((txn) => _mergeArtists(txn, sourceId, targetId));
    appDb.notifyChanged();
    return targetId;
  }

  Future<Set<int>> _albumsOfArtist(DatabaseExecutor txn, int artistId, String name) async {
    final rows = await txn.rawQuery(
      'SELECT DISTINCT album_id FROM tracks WHERE album_id IS NOT NULL AND (artist_id = ? OR album_artist = ? COLLATE NOCASE) '
      'UNION SELECT id FROM albums WHERE artist_id = ?',
      [artistId, name, artistId],
    );
    return {for (final r in rows) r.values.first as int};
  }

  Future<void> _regroupAndRefresh(DatabaseExecutor txn, Iterable<int> albumIds) async {
    for (final id in albumIds) {
      final survivor = await _regroupAlbum(txn, id);
      await _refreshAlbum(txn, survivor);
    }
    await _deleteOrphanArtists(txn);
  }

  Future<void> _mergeArtists(DatabaseExecutor txn, int sourceId, int targetId) async {
    final s = await txn.query('artists', where: 'id = ?', whereArgs: [sourceId], limit: 1);
    final t = await txn.query('artists', where: 'id = ?', whereArgs: [targetId], limit: 1);
    if (s.isEmpty || t.isEmpty) return;
    final source = s.first, target = t.first;
    final sourceName = source['name'] as String;
    final targetName = target['name'] as String;
    final touched = await _albumsOfArtist(txn, sourceId, sourceName);
    await txn.update('tracks', {'artist_id': targetId, 'artist_name': targetName}, where: 'artist_id = ?', whereArgs: [sourceId]);
    await txn.update('tracks', {'album_artist': targetName}, where: 'album_artist = ? COLLATE NOCASE', whereArgs: [sourceName]);
    await txn.update('albums', {'artist_id': targetId, 'artist_name': targetName}, where: 'artist_id = ?', whereArgs: [sourceId]);
    // keep whatever the duplicate knew that the survivor does not
    final carry = <String, Object?>{
      if (source['followed'] == 1 && target['followed'] != 1) 'followed': 1,
      for (final k in const ['mb_artist_id', 'bio', 'bio_source', 'image_path', 'image_url'])
        if (target[k] == null && source[k] != null) k: source[k],
    };
    if (carry.isNotEmpty) await txn.update('artists', carry, where: 'id = ?', whereArgs: [targetId]);
    await txn.delete('artists', where: 'id = ?', whereArgs: [sourceId]);
    await _regroupAndRefresh(txn, touched);
  }

  /// Writes artist columns directly, including clearing them with null (unlike [updateArtist]).
  Future<void> updateArtistFields(int id, Map<String, Object?> values) async {
    if (values.isEmpty) return;
    await db.update('artists', values, where: 'id = ?', whereArgs: [id]);
    appDb.notifyChanged();
  }

  Future<List<({String name, int count})>> genres() async {
    final rows = await db.rawQuery(
      "SELECT genre AS name, COUNT(*) AS n FROM tracks WHERE missing = 0 AND genre IS NOT NULL AND genre != '' "
      'GROUP BY genre COLLATE NOCASE ORDER BY genre COLLATE NOCASE',
    );
    return [for (final r in rows) (name: r['name'] as String, count: r['n'] as int)];
  }

  Future<List<({String path, int count})>> folders() async {
    final rows = await db.rawQuery(
      "SELECT folder AS path, COUNT(*) AS n FROM tracks WHERE missing = 0 AND folder IS NOT NULL AND folder != '' "
      'GROUP BY folder ORDER BY folder COLLATE NOCASE',
    );
    return [for (final r in rows) (path: r['path'] as String, count: r['n'] as int)];
  }

  // ------------------------------------------------------------------- search

  /// Turns free text into an FTS4 prefix query ("bea jud" -> `bea* jud*`).
  static String ftsQuery(String input) {
    final tokens = RegExp(r'[\p{L}\p{N}]+', unicode: true).allMatches(input).map((m) => m.group(0)!).toList();
    if (tokens.isEmpty) return '';
    return tokens.map((t) => '$t*').join(' ');
  }

  Future<List<Track>> searchTracks(String query, {int limit = 100}) async {
    final q = ftsQuery(query);
    if (q.isEmpty) return [];
    final rows = await db.rawQuery(
      'SELECT t.* FROM tracks t JOIN tracks_fts f ON f.rowid = t.id '
      'WHERE tracks_fts MATCH ? AND t.missing = 0 ORDER BY t.play_count DESC, t.title COLLATE NOCASE LIMIT ?',
      [q, limit],
    );
    return rows.map(Track.fromMap).toList();
  }

  static String _escapeLike(String s) => s.replaceAll('\\', '\\\\').replaceAll('%', '\\%').replaceAll('_', '\\_');

  // ---------------------------------------------------------------- statistics

  Future<void> recordPlay(int trackId) async {
    await db.rawUpdate(
      'UPDATE tracks SET play_count = play_count + 1, last_played = ? WHERE id = ?',
      [_now, trackId],
    );
    appDb.notifyChanged();
  }

  Future<void> setRating(int trackId, int rating) => updateTrackColumns(trackId, {'rating': rating.clamp(0, 5)});

  Future<void> setLoved(int trackId, bool loved) => updateTrackColumns(trackId, {'loved': loved ? 1 : 0});

  // ---------------------------------------------------------------- playlists

  Future<List<Playlist>> playlists() async {
    final rows = await db.rawQuery(
      'SELECT p.*, (SELECT COUNT(*) FROM playlist_tracks pt WHERE pt.playlist_id = p.id) AS track_count '
      'FROM playlists p ORDER BY p.name COLLATE NOCASE',
    );
    return rows.map(Playlist.fromMap).toList();
  }

  Future<Playlist?> playlistById(int id) async {
    final rows = await db.rawQuery(
      'SELECT p.*, (SELECT COUNT(*) FROM playlist_tracks pt WHERE pt.playlist_id = p.id) AS track_count '
      'FROM playlists p WHERE p.id = ?',
      [id],
    );
    return rows.isEmpty ? null : Playlist.fromMap(rows.first);
  }

  Future<int> createPlaylist(String name, {SmartRules? smart, String? coverPath}) async {
    final id = await db.insert('playlists', {
      'name': name.trim().isEmpty ? 'New playlist' : name.trim(),
      'is_smart': smart == null ? 0 : 1,
      'smart_rules': smart?.toJson(),
      'cover_path': coverPath,
      'created_at': _now,
      'updated_at': _now,
    });
    appDb.notifyChanged();
    return id;
  }

  Future<void> renamePlaylist(int id, String name) async {
    await db.update('playlists', {'name': name.trim(), 'updated_at': _now}, where: 'id = ?', whereArgs: [id]);
    appDb.notifyChanged();
  }

  /// Sets or clears (null) the playlist's own picture.
  Future<void> setPlaylistCover(int id, String? coverPath) async {
    await db.update('playlists', {'cover_path': coverPath, 'updated_at': _now}, where: 'id = ?', whereArgs: [id]);
    appDb.notifyChanged();
  }

  Future<void> updateSmartRules(int id, SmartRules rules) async {
    await db.update('playlists', {'smart_rules': rules.toJson(), 'is_smart': 1, 'updated_at': _now}, where: 'id = ?', whereArgs: [id]);
    appDb.notifyChanged();
  }

  Future<void> deletePlaylist(int id) async {
    await db.delete('playlists', where: 'id = ?', whereArgs: [id]);
    appDb.notifyChanged();
  }

  Future<void> addToPlaylist(int playlistId, Iterable<int> trackIds) async {
    await db.transaction((txn) async {
      var pos = Sqflite.firstIntValue(
              await txn.rawQuery('SELECT COALESCE(MAX(position), -1) FROM playlist_tracks WHERE playlist_id = ?', [playlistId])) ??
          -1;
      for (final id in trackIds) {
        pos++;
        await txn.insert('playlist_tracks', {'playlist_id': playlistId, 'track_id': id, 'position': pos});
      }
      await txn.update('playlists', {'updated_at': _now}, where: 'id = ?', whereArgs: [playlistId]);
    });
    appDb.notifyChanged();
  }

  /// Removes one entry (by its playlist_tracks row id) and closes the position gap.
  Future<void> removeFromPlaylist(int playlistId, int entryId) async {
    await db.transaction((txn) async {
      await txn.delete('playlist_tracks', where: 'id = ? AND playlist_id = ?', whereArgs: [entryId, playlistId]);
      await _renumber(txn, playlistId);
    });
    appDb.notifyChanged();
  }

  Future<void> reorderPlaylist(int playlistId, int oldIndex, int newIndex) async {
    await db.transaction((txn) async {
      final rows = await txn.query('playlist_tracks', columns: ['id'], where: 'playlist_id = ?', whereArgs: [playlistId], orderBy: 'position');
      final ids = rows.map((r) => r['id'] as int).toList();
      if (oldIndex < 0 || oldIndex >= ids.length) return;
      final moved = ids.removeAt(oldIndex);
      ids.insert(newIndex.clamp(0, ids.length), moved);
      for (var i = 0; i < ids.length; i++) {
        await txn.update('playlist_tracks', {'position': i}, where: 'id = ?', whereArgs: [ids[i]]);
      }
    });
    appDb.notifyChanged();
  }

  Future<void> _renumber(DatabaseExecutor txn, int playlistId) async {
    final rows = await txn.query('playlist_tracks', columns: ['id'], where: 'playlist_id = ?', whereArgs: [playlistId], orderBy: 'position');
    for (var i = 0; i < rows.length; i++) {
      await txn.update('playlist_tracks', {'position': i}, where: 'id = ?', whereArgs: [rows[i]['id']]);
    }
  }

  /// Entries of a manual playlist, keeping the row id so duplicates can be removed one by one.
  Future<List<({int entryId, Track track})>> playlistEntries(int playlistId) async {
    final rows = await db.rawQuery(
      'SELECT pt.id AS entry_id, t.* FROM playlist_tracks pt JOIN tracks t ON t.id = pt.track_id '
      'WHERE pt.playlist_id = ? AND t.missing = 0 ORDER BY pt.position',
      [playlistId],
    );
    return [for (final r in rows) (entryId: r['entry_id'] as int, track: Track.fromMap(r))];
  }

  /// Tracks of a playlist, evaluating smart rules on the fly.
  Future<List<Track>> playlistTracks(Playlist p) async {
    if (p.isSmart) {
      final q = SmartRules.parse(p.smartRules).toQuery(nowSeconds: _now);
      return (await db.rawQuery(q.sql, q.args)).map(Track.fromMap).toList();
    }
    return (await playlistEntries(p.id)).map((e) => e.track).toList();
  }

  // ------------------------------------------------------------------- lyrics

  Future<LyricsRow?> lyricsForTrack(int trackId) async {
    final rows = await db.query('lyrics', where: 'track_id = ?', whereArgs: [trackId], limit: 1);
    return rows.isEmpty ? null : LyricsRow.fromMap(rows.first);
  }

  Future<void> saveLyrics(
    int trackId, {
    String? plainText,
    String? syncedLrc,
    required String source,
    bool instrumental = false,
  }) async {
    await db.transaction((txn) async {
      await txn.insert(
        'lyrics',
        {
          'track_id': trackId,
          'plain_text': plainText,
          'synced_lrc': syncedLrc,
          'source': source,
          'instrumental': instrumental ? 1 : 0,
          'fetched_at': _now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      final id = Sqflite.firstIntValue(await txn.rawQuery('SELECT id FROM lyrics WHERE track_id = ?', [trackId]));
      await txn.update('tracks', {'lyrics_id': id}, where: 'id = ?', whereArgs: [trackId]);
    });
    appDb.notifyChanged();
  }

  Future<void> deleteLyrics(int trackId) async {
    await db.delete('lyrics', where: 'track_id = ?', whereArgs: [trackId]);
    await db.update('tracks', {'lyrics_id': null, 'lyrics_offset_ms': 0}, where: 'id = ?', whereArgs: [trackId]);
    appDb.notifyChanged();
  }

  Future<void> setLyricsOffset(int trackId, int offsetMs) => updateTrackColumns(trackId, {'lyrics_offset_ms': offsetMs});

  // -------------------------------------------------------------------- queue

  Future<void> saveQueue(List<Map<String, Object?>> items) async {
    await db.transaction((txn) async {
      await txn.delete('queue_items');
      for (var i = 0; i < items.length; i++) {
        await txn.insert('queue_items', {'position': i, 'json': jsonEncode(items[i])});
      }
    });
  }

  Future<List<Map<String, Object?>>> loadQueue() async {
    final rows = await db.query('queue_items', orderBy: 'position');
    return rows.map((r) => (jsonDecode(r['json'] as String) as Map).cast<String, Object?>()).toList();
  }

  // ------------------------------------------------------------------ backup

  /// Everything a user would be upset to lose: playlists, ratings, play counts,
  /// loved flags, lyrics offsets. Tracks are identified by file path + MusicBrainz id.
  Future<Map<String, Object?>> exportUserData() async {
    final tracks = await db.rawQuery(
      'SELECT file_path, mb_recording_id, title, artist_name, play_count, last_played, rating, loved, lyrics_offset_ms '
      'FROM tracks WHERE play_count > 0 OR rating > 0 OR loved = 1 OR lyrics_offset_ms != 0',
    );
    final playlists = await db.query('playlists');
    final entries = await db.rawQuery(
      'SELECT pt.playlist_id, pt.position, t.file_path, t.mb_recording_id, t.title, t.artist_name '
      'FROM playlist_tracks pt JOIN tracks t ON t.id = pt.track_id ORDER BY pt.playlist_id, pt.position',
    );
    final wishlist = await db.query('wishlist');
    final feeds = await db.query('podcast_feeds');
    final radios = await db.query('radio_favorites');
    return {
      'version': 1,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'tracks': tracks,
      'playlists': playlists,
      'playlistEntries': entries,
      'wishlist': wishlist,
      'podcastFeeds': feeds,
      'radioFavorites': radios,
    };
  }

  /// Merges a backup produced by [exportUserData] into the current library.
  /// Returns how many tracks were matched.
  Future<int> importUserData(Map<String, dynamic> data) async {
    var matched = 0;
    await db.transaction((txn) async {
      Future<int?> findTrack(Map<String, dynamic> e) async {
        final path = e['file_path'] as String?;
        if (path != null) {
          final r = await txn.query('tracks', columns: ['id'], where: 'file_path = ?', whereArgs: [path], limit: 1);
          if (r.isNotEmpty) return r.first['id'] as int;
        }
        final mb = e['mb_recording_id'] as String?;
        if (mb != null && mb.isNotEmpty) {
          final r = await txn.query('tracks', columns: ['id'], where: 'mb_recording_id = ?', whereArgs: [mb], limit: 1);
          if (r.isNotEmpty) return r.first['id'] as int;
        }
        final title = e['title'] as String?;
        final artist = e['artist_name'] as String?;
        if (title != null && artist != null) {
          final r = await txn.query('tracks',
              columns: ['id'], where: 'title = ? COLLATE NOCASE AND artist_name = ? COLLATE NOCASE', whereArgs: [title, artist], limit: 1);
          if (r.isNotEmpty) return r.first['id'] as int;
        }
        return null;
      }

      for (final raw in (data['tracks'] as List? ?? const [])) {
        final e = (raw as Map).cast<String, dynamic>();
        final id = await findTrack(e);
        if (id == null) continue;
        matched++;
        await txn.update(
          'tracks',
          {
            'play_count': e['play_count'] ?? 0,
            'last_played': e['last_played'],
            'rating': e['rating'] ?? 0,
            'loved': e['loved'] ?? 0,
            'lyrics_offset_ms': e['lyrics_offset_ms'] ?? 0,
          },
          where: 'id = ?',
          whereArgs: [id],
        );
      }

      final idMap = <int, int>{};
      for (final raw in (data['playlists'] as List? ?? const [])) {
        final p = (raw as Map).cast<String, dynamic>();
        final newId = await txn.insert('playlists', {
          'name': p['name'],
          'is_smart': p['is_smart'] ?? 0,
          'smart_rules': p['smart_rules'],
          'created_at': p['created_at'] ?? _now,
          'updated_at': _now,
        });
        idMap[p['id'] as int] = newId;
      }
      var pos = <int, int>{};
      for (final raw in (data['playlistEntries'] as List? ?? const [])) {
        final e = (raw as Map).cast<String, dynamic>();
        final target = idMap[e['playlist_id'] as int];
        final tid = await findTrack(e);
        if (target == null || tid == null) continue;
        final p = pos[target] ?? 0;
        pos[target] = p + 1;
        await txn.insert('playlist_tracks', {'playlist_id': target, 'track_id': tid, 'position': p});
      }
      for (final raw in (data['wishlist'] as List? ?? const [])) {
        final w = (raw as Map).cast<String, dynamic>();
        await txn.insert('wishlist', {
          'artist': w['artist'],
          'title': w['title'],
          'album': w['album'],
          'isrc': w['isrc'],
          'origin': w['origin'],
          'status': w['status'] ?? 'pending',
          'created_at': w['created_at'] ?? _now,
        });
      }
      for (final raw in (data['podcastFeeds'] as List? ?? const [])) {
        final f = (raw as Map).cast<String, dynamic>();
        await txn.insert('podcast_feeds', {'title': f['title'], 'feed_url': f['feed_url'], 'image_url': f['image_url'], 'author': f['author']},
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      for (final raw in (data['radioFavorites'] as List? ?? const [])) {
        final r = (raw as Map).cast<String, dynamic>();
        await txn.insert(
            'radio_favorites',
            {
              'station_uuid': r['station_uuid'],
              'name': r['name'],
              'stream_url': r['stream_url'],
              'favicon': r['favicon'],
              'country': r['country'],
              'tags': r['tags'],
            },
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    });
    appDb.notifyChanged();
    return matched;
  }
}
