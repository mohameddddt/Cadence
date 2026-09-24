import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/core/db/app_database.dart';
import 'package:musicplayer/core/db/schema.dart';
import 'package:sqflite/sqlite_api.dart';

import 'helpers/test_db.dart';

void main() {
  test('fresh database has every expected table, trigger and FTS index', () async {
    final db = await openTestDb();
    final names = (await db.db.rawQuery("SELECT name FROM sqlite_master WHERE type IN ('table','trigger')"))
        .map((r) => r['name'] as String)
        .toSet();
    for (final t in [
      'artists', 'albums', 'tracks', 'tracks_fts', 'playlists', 'playlist_tracks', 'lyrics', 'download_jobs',
      'scrobble_queue', 'api_cache', 'queue_items', 'wishlist', 'podcast_feeds', 'radio_favorites',
      'tracks_ai', 'tracks_au', 'tracks_ad',
    ]) {
      expect(names, contains(t));
    }
    expect((await db.db.rawQuery('PRAGMA user_version')).single['user_version'], schemaVersion);
    await db.close();
  });

  test('every path has an index the plan asks for (mbRecordingId, sourceUrl, filePath)', () async {
    final db = await openTestDb();
    final idx = (await db.db.rawQuery("SELECT name FROM sqlite_master WHERE type='index'")).map((r) => r['name']).toSet();
    expect(idx, containsAll(['idx_tracks_mb_recording', 'idx_tracks_source_url']));
    final cols = await db.db.rawQuery('PRAGMA index_list(tracks)');
    expect(cols.any((c) => (c['unique'] as int) == 1), isTrue, reason: 'file_path is unique');
    await db.close();
  });

  test('migrations run in order and keep existing rows', () async {
    final factory = testFactory();
    final dir = Directory.systemTemp.createTempSync('mig');
    final path = '${dir.path}/m.db';
    // "v1 app": a table with one row.
    final v1 = await AppDatabase.open(
      path: path,
      factory: factory,
      version: 1,
      create: const ['CREATE TABLE notes(id INTEGER PRIMARY KEY, body TEXT)'],
      migrationList: const [],
      withSearchIndex: false,
      singleInstance: false,
    );
    await v1.db.insert('notes', {'body': 'hello'});
    await v1.close();
    // The user updates the app: schema v3 with two migrations.
    final v3 = await AppDatabase.open(
      path: path,
      factory: factory,
      version: 3,
      create: const ['CREATE TABLE notes(id INTEGER PRIMARY KEY, body TEXT, pinned INTEGER DEFAULT 0, tag TEXT)'],
      migrationList: const [
        Migration(from: 1, to: 2, statements: ['ALTER TABLE notes ADD COLUMN pinned INTEGER DEFAULT 0']),
        Migration(from: 2, to: 3, statements: ['ALTER TABLE notes ADD COLUMN tag TEXT']),
      ],
      withSearchIndex: false,
      singleInstance: false,
    );
    final rows = await v3.db.query('notes');
    expect(rows.single['body'], 'hello');
    expect(rows.single.containsKey('pinned'), isTrue);
    expect(rows.single.containsKey('tag'), isTrue);
    await v3.close();
    dir.deleteSync(recursive: true);
  });

  test('a missing migration step fails loudly instead of corrupting data', () async {
    final db = await openDatabaseForTest();
    expect(
      () => AppDatabase.runMigrations(db, 1, 3, const [Migration(from: 2, to: 3, statements: [])]),
      throwsA(isA<StateError>()),
    );
    await db.close();
  });
}

Future<Database> openDatabaseForTest() => testFactory().openDatabase(inMemoryDatabasePath);
