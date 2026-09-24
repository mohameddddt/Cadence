import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/core/library/library_repository.dart';
import 'package:musicplayer/core/library/smart_rules.dart';
import 'package:musicplayer/core/models/track.dart';

import 'helpers/test_db.dart';

TrackDraft draft(
  String path,
  String title, {
  String? artist,
  String? album,
  String? albumArtist,
  String folder = '/m/a',
  int? no,
  int? year,
  String? genre,
  String? mbRecording,
  String? sourceUrl,
  String? hash,
}) =>
    TrackDraft(
      filePath: path,
      title: title,
      artist: artist,
      album: album,
      albumArtist: albumArtist,
      folder: folder,
      trackNo: no,
      year: year,
      genre: genre,
      durationMs: 200000,
      mbRecordingId: mbRecording,
      sourceUrl: sourceUrl,
      audioHash: hash,
    );

void main() {
  late LibraryRepository repo;

  setUp(() async {
    repo = await openTestRepo();
  });

  tearDown(() async => repo.appDb.close());

  test('upsert creates artist + album and re-upsert keeps play stats', () async {
    final id = await repo.upsertTrack(draft('/m/a/1.mp3', 'One', artist: 'The Band', album: 'First', no: 1, year: 2001));
    await repo.recordPlay(id);
    await repo.recordPlay(id);
    final again = await repo.upsertTrack(draft('/m/a/1.mp3', 'One (fixed)', artist: 'The Band', album: 'First', no: 1, year: 2001));
    expect(again, id);
    final t = (await repo.trackById(id))!;
    expect(t.title, 'One (fixed)');
    expect(t.playCount, 2);
    expect((await repo.artists()).single.name, 'The Band');
    final album = (await repo.albums()).single;
    expect(album.title, 'First');
    expect(album.year, 2001);
    expect(album.displayArtist, 'The Band');
    expect(album.trackCount, 1);
  });

  test('tracks of one album by different artists collapse into a Various Artists compilation', () async {
    await repo.upsertTracks([
      draft('/m/c/1.mp3', 'A', artist: 'Alice', album: 'Hits', folder: '/m/c'),
      draft('/m/c/2.mp3', 'B', artist: 'Bob', album: 'Hits', folder: '/m/c'),
    ]);
    final albums = await repo.albums();
    expect(albums, hasLength(1));
    expect(albums.single.displayArtist, 'Various Artists');
    expect(albums.single.compilation, isTrue);
    expect(albums.single.trackCount, 2);
  });

  test('same album title in different folders with different album artists stays separate', () async {
    await repo.upsertTracks([
      draft('/m/x/1.mp3', 'A', artist: 'X', albumArtist: 'X', album: 'Greatest Hits', folder: '/m/x'),
      draft('/m/y/1.mp3', 'B', artist: 'Y', albumArtist: 'Y', album: 'Greatest Hits', folder: '/m/y'),
    ]);
    expect(await repo.albums(), hasLength(2));
  });

  test('a MusicBrainz release id merges tracks regardless of folder', () async {
    TrackDraft d(String p, String f) => TrackDraft(
        filePath: p, title: p, artist: 'A', album: 'Album', folder: f, mbReleaseId: 'rel-1', durationMs: 1);
    await repo.upsertTracks([d('/1.mp3', '/f1'), d('/2.mp3', '/f2')]);
    final albums = await repo.albums();
    expect(albums, hasLength(1));
    expect(albums.single.mbReleaseId, 'rel-1');
  });

  test('moving a track to another album removes the emptied album', () async {
    final id = await repo.upsertTrack(draft('/m/a/1.mp3', 'One', artist: 'A', album: 'Old'));
    await repo.upsertTrack(draft('/m/a/1.mp3', 'One', artist: 'A', album: 'New'));
    final titles = (await repo.albums()).map((a) => a.title).toList();
    expect(titles, ['New']);
    expect((await repo.trackById(id))!.albumTitle, 'New');
  });

  test('deleteTracks removes orphan albums and artists', () async {
    final id = await repo.upsertTrack(draft('/m/a/1.mp3', 'One', artist: 'Solo', album: 'Only'));
    expect(await repo.deleteTracks([id]), 1);
    expect(await repo.albums(), isEmpty);
    expect(await repo.artists(), isEmpty);
  });

  test('full-text search matches prefixes across title, artist and album, incl. unicode', () async {
    await repo.upsertTracks([
      draft('/1.mp3', 'Yesterday', artist: 'The Beatles', album: 'Help!'),
      draft('/2.mp3', 'Über Alles', artist: 'Rammstein', album: 'Reise'),
      draft('/3.mp3', 'Something', artist: 'The Beatles', album: 'Abbey Road'),
    ]);
    expect((await repo.searchTracks('beat')).map((t) => t.title), containsAll(['Yesterday', 'Something']));
    expect((await repo.searchTracks('yest bea')).map((t) => t.title), ['Yesterday']);
    expect((await repo.searchTracks('über')).map((t) => t.title), ['Über Alles']);
    expect(await repo.searchTracks('zzz'), isEmpty);
    expect(await repo.searchTracks('"; DROP TABLE tracks; --'), isEmpty);
  });

  test('search index follows renames and deletions', () async {
    final id = await repo.upsertTrack(draft('/1.mp3', 'Old Name', artist: 'A'));
    await repo.updateTrackColumns(id, {'title': 'Brand New'});
    expect(await repo.searchTracks('old'), isEmpty);
    expect((await repo.searchTracks('brand')).single.id, id);
    await repo.deleteTracks([id]);
    expect(await repo.searchTracks('brand'), isEmpty);
  });

  test('duplicate detection by source url, recording id and hash', () async {
    final id = await repo.upsertTrack(draft('/1.mp3', 'X', artist: 'A', mbRecording: 'rec-1', sourceUrl: 'https://y/1', hash: 'h1'));
    expect((await repo.findDuplicate(sourceUrl: 'https://y/1'))!.id, id);
    expect((await repo.findDuplicate(mbRecordingId: 'rec-1'))!.id, id);
    expect((await repo.findDuplicate(audioHash: 'h1'))!.id, id);
    expect(await repo.findDuplicate(sourceUrl: 'https://y/2', mbRecordingId: 'rec-2', audioHash: 'h2'), isNull);
    expect((await repo.trackById(id))!.identifyState, IdentifyState.matched);
  });

  test('playlists keep order, allow duplicates and reorder', () async {
    final a = await repo.upsertTrack(draft('/a.mp3', 'A'));
    final b = await repo.upsertTrack(draft('/b.mp3', 'B'));
    final c = await repo.upsertTrack(draft('/c.mp3', 'C'));
    final pl = await repo.createPlaylist('Mix');
    await repo.addToPlaylist(pl, [a, b, c, a]);
    var e = await repo.playlistEntries(pl);
    expect(e.map((x) => x.track.title), ['A', 'B', 'C', 'A']);
    await repo.reorderPlaylist(pl, 0, 2);
    e = await repo.playlistEntries(pl);
    expect(e.map((x) => x.track.title), ['B', 'C', 'A', 'A']);
    await repo.removeFromPlaylist(pl, e.first.entryId);
    e = await repo.playlistEntries(pl);
    expect(e.map((x) => x.track.title), ['C', 'A', 'A']);
    expect((await repo.playlists()).single.trackCount, 3);
    await repo.deletePlaylist(pl);
    expect(await repo.playlists(), isEmpty);
    final rows = await repo.db.query('playlist_tracks');
    expect(rows, isEmpty, reason: 'cascade delete');
  });

  test('smart playlist evaluates rules against the live library', () async {
    final a = await repo.upsertTrack(draft('/a.mp3', 'Rock A', artist: 'X', genre: 'Rock', year: 1999));
    await repo.upsertTrack(draft('/b.mp3', 'Jazz B', artist: 'Y', genre: 'Jazz', year: 2005));
    await repo.upsertTrack(draft('/c.mp3', 'Rock C', artist: 'Z', genre: 'Rock', year: 2010));
    await repo.recordPlay(a);
    final rules = const SmartRules(
      conditions: [
        SmartCondition(SmartField.genre, SmartOp.equals, 'rock'),
        SmartCondition(SmartField.year, SmartOp.greaterThan, '2000'),
      ],
    );
    final id = await repo.createPlaylist('Modern rock', smart: rules);
    final p = (await repo.playlistById(id))!;
    expect((await repo.playlistTracks(p)).map((t) => t.title), ['Rock C']);

    final any = SmartRules(matchAll: false, conditions: rules.conditions, sort: TrackSort.title);
    await repo.updateSmartRules(id, any);
    final p2 = (await repo.playlistById(id))!;
    expect((await repo.playlistTracks(p2)).map((t) => t.title), ['Jazz B', 'Rock A', 'Rock C']);

    const played = SmartRules(conditions: [SmartCondition(SmartField.playCount, SmartOp.greaterThan, '0')]);
    final q = played.toQuery(nowSeconds: 0);
    expect((await repo.db.rawQuery(q.sql, q.args)).single['title'], 'Rock A');
  });

  test('smart rules escape LIKE wildcards and ignore unparsable numbers', () {
    const r = SmartRules(conditions: [
      SmartCondition(SmartField.title, SmartOp.contains, '50%_off'),
      SmartCondition(SmartField.year, SmartOp.greaterThan, 'abc'),
    ]);
    final q = r.toQuery(nowSeconds: 0);
    expect(q.args, ['%50\\%\\_off%']);
    expect(q.sql, isNot(contains('t.year')));
  });

  test('smart rules round-trip through JSON', () {
    const r = SmartRules(
      matchAll: false,
      conditions: [SmartCondition(SmartField.artist, SmartOp.contains, 'abba')],
      sort: TrackSort.playCount,
      descending: true,
      limit: 10,
    );
    final back = SmartRules.parse(r.toJson());
    expect(back.matchAll, isFalse);
    expect(back.conditions.single.value, 'abba');
    expect(back.sort, TrackSort.playCount);
    expect(back.descending, isTrue);
    expect(back.limit, 10);
  });

  test('lyrics are stored per track and linked', () async {
    final id = await repo.upsertTrack(draft('/a.mp3', 'A'));
    await repo.saveLyrics(id, plainText: 'la la', syncedLrc: '[00:01.00]la la', source: 'lrclib');
    final l = (await repo.lyricsForTrack(id))!;
    expect(l.hasSynced, isTrue);
    expect((await repo.trackById(id))!.lyricsId, l.id);
    await repo.saveLyrics(id, plainText: 'new', source: 'manual');
    expect((await repo.lyricsForTrack(id))!.plainText, 'new');
    await repo.deleteLyrics(id);
    expect(await repo.lyricsForTrack(id), isNull);
    expect((await repo.trackById(id))!.lyricsId, isNull);
  });

  test('queue persists and reloads in order', () async {
    await repo.saveQueue([
      {'id': '1', 'title': 'a'},
      {'id': '2', 'title': 'b'},
    ]);
    expect((await repo.loadQueue()).map((e) => e['title']), ['a', 'b']);
    await repo.saveQueue([]);
    expect(await repo.loadQueue(), isEmpty);
  });

  test('backup export/import restores ratings, play counts and playlists by matching tracks', () async {
    final a = await repo.upsertTrack(draft('/a.mp3', 'Song A', artist: 'X', mbRecording: 'rec-a'));
    await repo.recordPlay(a);
    await repo.setRating(a, 4);
    await repo.setLoved(a, true);
    final pl = await repo.createPlaylist('Faves');
    await repo.addToPlaylist(pl, [a]);
    final dump = await repo.exportUserData();

    final fresh = await openTestRepo();
    // Same song, different path (e.g. new phone) - matched through the MusicBrainz id.
    final b = await fresh.upsertTrack(draft('/new/place/a.mp3', 'Song A', artist: 'X', mbRecording: 'rec-a'));
    expect(await fresh.importUserData(dump), 1);
    final t = (await fresh.trackById(b))!;
    expect(t.playCount, 1);
    expect(t.rating, 4);
    expect(t.loved, isTrue);
    final restored = (await fresh.playlists()).single;
    expect(restored.name, 'Faves');
    expect((await fresh.playlistEntries(restored.id)).single.track.id, b);
    await fresh.appDb.close();
  });

  test('watch re-runs the query after a change', () async {
    final seen = <int>[];
    final sub = repo.appDb.watch(() => repo.trackCount()).listen(seen.add);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await repo.upsertTrack(draft('/a.mp3', 'A'));
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await sub.cancel();
    expect(seen, [0, 1]);
  });
}
