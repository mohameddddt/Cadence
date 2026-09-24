import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/core/library/library_repository.dart';
import 'package:musicplayer/core/models/track.dart';
import 'package:musicplayer/features/lyrics/lrc_parser.dart';
import 'package:musicplayer/features/lyrics/lyrics_clients.dart';
import 'package:musicplayer/features/lyrics/lyrics_service.dart';
import 'package:musicplayer/features/metadata/tag_writer.dart';
import 'package:musicplayer/platform/bridges.dart';

import 'helpers/fake_http.dart';
import 'helpers/fakes.dart';
import 'helpers/test_db.dart';

void main() {
  group('LrclibClient (recorded responses)', () {
    late FakeHttpAdapter net;
    late LrclibClient client;

    setUp(() {
      net = FakeHttpAdapter();
      client = LrclibClient(fakeHttp(net));
    });

    test('exact get returns synced lyrics that our LRC parser understands', () async {
      net.onFixture('/api/get', 'lrclib_get.json');
      final r = (await client.get(title: 'Bohemian Rhapsody', artist: 'Queen', album: 'A Night at the Opera', durationSec: 354))!;
      expect(r.hasSynced, isTrue);
      expect(r.plain, startsWith('Is this the real life?'));
      expect(r.instrumental, isFalse);
      final q = net.requests.single.uri.queryParameters;
      expect(q['track_name'], 'Bohemian Rhapsody');
      expect(q['artist_name'], 'Queen');
      expect(q['duration'], '354');
      final doc = LrcDocument.parse(r.synced!);
      expect(doc.lines.length, greaterThan(40));
      expect(doc.lines.first.text, 'Is this the real life? Is this just fantasy?');
      expect(doc.lines.first.time, const Duration(milliseconds: 150));
      expect(doc.indexAt(const Duration(seconds: 60)), greaterThan(3));
    });

    test('404 is null', () async {
      net.on('/api/get', (_) => FakeResponse.notFound());
      expect(await client.get(title: 'x', artist: 'y'), isNull);
    });

    test('search returns several candidates', () async {
      net.onFixture('/api/search', 'lrclib_search.json');
      final r = await client.search(query: 'Bohemian Rhapsody Queen');
      expect(r, hasLength(3));
      expect(r.first.artistName.toLowerCase(), contains('queen'));
    });

    test('bestMatch rejects results whose duration is far off and prefers synced ones', () {
      const wrongLength = LrclibResult(id: 1, trackName: 'Song', artistName: 'Band', durationSec: 250, plain: 'p', synced: '[00:01.00]x');
      const plainOnly = LrclibResult(id: 2, trackName: 'Song', artistName: 'Band', durationSec: 200, plain: 'p');
      const synced = LrclibResult(id: 3, trackName: 'Song', artistName: 'Band', durationSec: 201, plain: 'p', synced: '[00:01.00]x');
      expect(LrclibClient.bestMatch(const [wrongLength], title: 'Song', artist: 'Band', durationSec: 200), isNull);
      expect(LrclibClient.bestMatch(const [plainOnly, synced], title: 'Song', artist: 'Band', durationSec: 200)!.id, 3);
      expect(LrclibClient.bestMatch(const [plainOnly], title: 'Completely other', artist: 'Nobody', durationSec: 200), isNull);
    });
  });

  group('GeniusClient', () {
    test('returns song info and a link, never lyrics', () async {
      final net = FakeHttpAdapter()
        ..onFixture('/search', 'genius_search.json')
        ..onFixture('/songs/1063', 'genius_song.json');
      final g = GeniusClient(fakeHttp(net), token: () => 'TOKEN');
      final m = (await g.match(title: 'Bohemian Rhapsody', artist: 'Queen'))!;
      expect(m.id, 1063);
      expect(m.url, 'https://genius.com/Queen-bohemian-rhapsody-lyrics');
      final full = (await g.song(m.id))!;
      expect(full.description, contains('Freddie Mercury'));
      expect(net.requests.first.headers['Authorization'], 'Bearer TOKEN');
    });

    test('without a token nothing is requested', () async {
      final net = FakeHttpAdapter();
      final g = GeniusClient(fakeHttp(net), token: () => '');
      expect(await g.search('x'), isEmpty);
      expect(net.requests, isEmpty);
    });
  });

  group('LyricsService', () {
    late LibraryRepository repo;
    late FakeBridges bridges;
    late FakeHttpAdapter net;
    late LyricsService svc;
    late Directory dir;

    Future<void> setUpService([Map<String, Object> prefs = const {}]) async {
      repo = await openTestRepo();
      bridges = FakeBridges();
      net = FakeHttpAdapter();
      dir = Directory.systemTemp.createTempSync('lyr');
      final settings = await testSettings(prefs);
      final http = fakeHttp(net);
      svc = LyricsService(
        repo: repo,
        bridges: bridges,
        settings: settings,
        lrclib: LrclibClient(http),
        genius: GeniusClient(http, token: () => settings.geniusToken),
        tagWriter: TagWriter(repo: repo, bridges: bridges),
      );
    }

    Future<Track> addTrack({String title = 'Bohemian Rhapsody', String? artist = 'Queen', String? album = 'A Night at the Opera', String? path}) async {
      final id = await repo.upsertTrack(TrackDraft(
        filePath: path ?? '${dir.path}/song.mp3',
        title: title,
        artist: artist,
        album: album,
        durationMs: 354000,
        contentUri: 'content://media/external/audio/media/3',
      ));
      return (await repo.trackById(id))!;
    }

    setUp(() => setUpService());
    tearDown(() async {
      await repo.appDb.close();
      dir.deleteSync(recursive: true);
    });

    test('fetches from LRCLIB, stores it and serves later reads from the database', () async {
      net.onFixture('/api/get', 'lrclib_get.json');
      final t = await addTrack();
      final row = (await svc.lyricsFor(t))!;
      expect(row.hasSynced, isTrue);
      expect(row.source, 'lrclib');
      expect((await repo.trackById(t.id))!.lyricsId, row.id);
      net.requests.clear();
      final again = (await svc.lyricsFor(t))!;
      expect(again.id, row.id);
      expect(net.requests, isEmpty);
    });

    test('an embedded lyrics tag beats the network, and synced text inside it is detected', () async {
      final t = await addTrack();
      bridges.fakeTags.byKey[t.filePath] = const TagData(lyrics: '[00:01.00]hello\n[00:02.00]world');
      final row = (await svc.lyricsFor(t))!;
      expect(row.source, 'embedded');
      expect(row.hasSynced, isTrue);
      expect(row.plainText, 'hello\nworld');
      expect(net.requests, isEmpty);
    });

    test('a .lrc sidecar next to the file is used first', () async {
      final t = await addTrack();
      File('${dir.path}/song.lrc').writeAsStringSync('[00:05.00]from sidecar');
      final row = (await svc.lyricsFor(t))!;
      expect(row.source, 'sidecar');
      expect(LrcDocument.parse(row.syncedLrc!).lines.single.text, 'from sidecar');
    });

    test('falls back to fuzzy search when the exact lookup misses', () async {
      net.on('/api/get', (_) => FakeResponse.notFound());
      net.onFixture('/api/search', 'lrclib_search.json');
      final t = await addTrack();
      final row = await svc.lyricsFor(t);
      expect(row, isNotNull);
      expect(net.requestsTo('/api/search'), isNotEmpty);
    });

    test('a video-style title is cleaned before asking LRCLIB', () async {
      net.onFixture('/api/get', 'lrclib_get.json');
      final t = await addTrack(title: 'Bohemian Rhapsody (Official Video) [4K]');
      await svc.lyricsFor(t);
      expect(net.requests.first.uri.queryParameters['track_name'], 'Bohemian Rhapsody');
    });

    test('a genuine miss is remembered so we do not ask again for a while', () async {
      net.on('/api/get', (_) => FakeResponse.notFound());
      net.on('/api/search', (_) => FakeResponse.json([]));
      final t = await addTrack();
      expect(await svc.lyricsFor(t), isNull);
      final asked = net.requests.length;
      expect(await svc.lyricsFor(t), isNull);
      expect(net.requests.length, asked);
      // ...unless the user forces a refresh
      expect(await svc.lyricsFor(t, refresh: true), isNull);
      expect(net.requests.length, greaterThan(asked));
    });

    test('being offline is not remembered as a miss', () async {
      net.on('/api/', (_) => FakeResponse('down', status: 500));
      final t = await addTrack();
      expect(await svc.lyricsFor(t), isNull);
      expect(await repo.lyricsForTrack(t.id), isNull);
    });

    test('tracks without an artist cannot be looked up', () async {
      final t = await addTrack(artist: null);
      expect(await svc.lyricsFor(t), isNull);
      expect(net.requestsTo('lrclib'), isEmpty);
    });

    test('embedding into the file and a sidecar are optional settings', () async {
      await setUpService({'dl.embedLyrics': true, 'dl.writeLrc': true});
      net.onFixture('/api/get', 'lrclib_get.json');
      final t = await addTrack();
      await svc.lyricsFor(t);
      final write = bridges.fakeTags.writes.single;
      expect(write.update.values['lyrics'], contains('[00:00.15]'));
      expect(File('${dir.path}/song.lrc').existsSync(), isTrue);
    });

    test('manual edits are saved; LRC text becomes synced lyrics', () async {
      final t = await addTrack();
      var row = (await svc.saveManual(t, 'just some words'))!;
      expect(row.hasSynced, isFalse);
      expect(row.source, 'manual');
      row = (await svc.saveManual(t, '[00:01.00]timed'))!;
      expect(row.hasSynced, isTrue);
    });

    test('choosing another search result replaces the stored lyrics', () async {
      net.onFixture('/api/get', 'lrclib_get.json');
      final t = await addTrack();
      await svc.lyricsFor(t);
      const other = LrclibResult(id: 9, trackName: 'x', artistName: 'y', plain: 'other words');
      final row = (await svc.choose(t, other))!;
      expect(row.plainText, 'other words');
      expect(row.hasSynced, isFalse);
    });

    test('per-track sync offset is stored', () async {
      final t = await addTrack();
      await svc.setOffset(t, -750);
      expect((await repo.trackById(t.id))!.lyricsOffsetMs, -750);
    });

    test('instrumental tracks are recorded as such', () async {
      net.onJson('/api/get', {'id': 5, 'trackName': 'x', 'artistName': 'y', 'instrumental': true, 'plainLyrics': null, 'syncedLyrics': null});
      final t = await addTrack();
      final row = (await svc.lyricsFor(t))!;
      expect(row.instrumental, isTrue);
      expect(row.hasAny, isFalse);
    });
  });
}
