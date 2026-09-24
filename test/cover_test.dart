import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:musicplayer/core/library/library_repository.dart';
import 'package:musicplayer/core/models/track.dart';
import 'package:musicplayer/features/cover/cover_providers.dart';
import 'package:musicplayer/features/cover/cover_service.dart';
import 'package:musicplayer/features/cover/image_processing.dart';
import 'package:musicplayer/features/metadata/tag_writer.dart';

import 'helpers/fake_http.dart';
import 'helpers/fakes.dart';
import 'helpers/test_db.dart';

Uint8List makeImage(int w, int h, {img.ColorRgb8? color}) {
  final image = img.Image(width: w, height: h);
  img.fill(image, color: color ?? img.ColorRgb8(200, 30, 30));
  return Uint8List.fromList(img.encodeJpg(image, quality: 80));
}

const releaseId = '6defd963-fe91-4550-b18e-82c685603c2b';

void main() {
  group('ImageProcessing', () {
    test('a 16:9 thumbnail is centre-cropped to a square', () {
      final out = ImageProcessing.processCover(makeImage(1280, 720));
      final d = ImageProcessing.dimensions(out)!;
      expect(d.width, 720);
      expect(d.height, 720);
    });

    test('large squares are scaled down to 1200 px, small ones are left alone', () {
      final big = ImageProcessing.dimensions(ImageProcessing.processCover(makeImage(2400, 2400)))!;
      expect((big.width, big.height), (1200, 1200));
      final small = ImageProcessing.dimensions(ImageProcessing.processCover(makeImage(500, 500)))!;
      expect(small.width, 500);
    });

    test('the crop keeps the centre of the picture', () {
      final wide = img.Image(width: 300, height: 100);
      img.fill(wide, color: img.ColorRgb8(255, 0, 0)); // left third red...
      img.fillRect(wide, x1: 100, y1: 0, x2: 200, y2: 100, color: img.ColorRgb8(0, 0, 255)); // ...middle blue
      final out = img.decodeJpg(ImageProcessing.processCover(Uint8List.fromList(img.encodePng(wide))))!;
      final p = out.getPixel(50, 50);
      expect(p.b, greaterThan(200));
      expect(p.r, lessThan(60));
    });

    test('garbage is rejected with a FormatException', () {
      expect(() => ImageProcessing.processCover(Uint8List.fromList([1, 2, 3])), throwsFormatException);
    });

    test('averageColor is close to a flat colour', () {
      final c = ImageProcessing.averageColor(makeImage(64, 64, color: img.ColorRgb8(10, 200, 10)))!;
      expect((c >> 8) & 0xFF, greaterThan(150));
    });
  });

  group('providers (recorded responses)', () {
    late FakeHttpAdapter net;

    setUp(() => net = FakeHttpAdapter());

    test('Cover Art Archive: picks the 1200 px front thumbnail and upgrades to https', () async {
      net.onFixture('coverartarchive.org/release/$releaseId', 'caa_index.json');
      final c = await CoverArtArchiveProvider(fakeHttp(net)).find(const CoverQuery(mbReleaseId: releaseId));
      expect(c, isNotNull);
      expect(c!.url, startsWith('https://'));
      expect(c.url, contains('1200'));
      expect(c.source, 'caa');
    });

    test('Cover Art Archive: no art (404) or no MBID is simply null', () async {
      net.on('coverartarchive.org', (_) => FakeResponse.notFound());
      final p = CoverArtArchiveProvider(fakeHttp(net));
      expect(await p.find(const CoverQuery(mbReleaseId: 'x')), isNull);
      expect(await p.find(const CoverQuery()), isNull);
      expect(await CoverArtArchiveProvider(fakeHttp(net), byReleaseGroup: true).find(const CoverQuery(mbReleaseId: 'x')), isNull);
    });

    test('release-group lookups use the release-group endpoint', () async {
      net.onFixture('coverartarchive.org/release-group/rg1', 'caa_index.json');
      final c = await CoverArtArchiveProvider(fakeHttp(net), byReleaseGroup: true).find(const CoverQuery(mbReleaseGroupId: 'rg1'));
      expect(c!.source, 'caa-group');
    });

    test('iTunes: enlarges the artwork url to 1200x1200 and checks the album name matches', () async {
      net.onFixture('itunes.apple.com/search', 'itunes_album.json');
      final p = ITunesCoverProvider(fakeHttp(net));
      final c = await p.find(const CoverQuery(artist: 'Queen', album: 'A Night at the Opera'));
      expect(c!.url, contains('1200x1200bb'));
      expect(c.url, isNot(contains('100x100')));
      expect(await p.find(const CoverQuery(artist: 'Queen', album: 'Totally Different Record')), isNull);
      expect(await p.find(const CoverQuery(artist: 'Someone Else', album: 'A Night at the Opera')), isNull);
    });

    test('Deezer: uses cover_xl', () async {
      net.onFixture('api.deezer.com/search/album', 'deezer_album_search.json');
      final c = await DeezerCoverProvider(fakeHttp(net)).find(const CoverQuery(artist: 'Queen', album: 'A Night at the Opera'));
      expect(c!.url, contains('dzcdn.net'));
      expect(net.requests.single.uri.queryParameters['q'], 'artist:"Queen" album:"A Night at the Opera"');
    });

    test('Last.fm: needs a key, skips the grey placeholder', () async {
      net.onJson('ws.audioscrobbler.com', {
        'album': {
          'image': [
            {'#text': 'https://lastfm.freetls.fastly.net/i/u/300x300/2a96cbd8b46e442fc41c2b86b821562f.png', 'size': 'extralarge'}
          ]
        }
      });
      expect(await LastFmCoverProvider(fakeHttp(net), apiKey: () => '').find(const CoverQuery(artist: 'a', album: 'b')), isNull);
      expect(await LastFmCoverProvider(fakeHttp(net), apiKey: () => 'K').find(const CoverQuery(artist: 'a', album: 'b')), isNull);
      final net2 = FakeHttpAdapter()
        ..onJson('ws.audioscrobbler.com', {
          'album': {
            'image': [
              {'#text': 'https://img/large.jpg', 'size': 'large'},
              {'#text': 'https://img/mega.jpg', 'size': 'mega'},
            ]
          }
        });
      expect((await LastFmCoverProvider(fakeHttp(net2), apiKey: () => 'K').find(const CoverQuery(artist: 'a', album: 'b')))!.url, 'https://img/mega.jpg');
    });

    test('providers swallow HTTP failures', () async {
      net.on('', (_) => FakeResponse('boom', status: 500));
      final http = fakeHttp(net);
      expect(await ITunesCoverProvider(http).find(const CoverQuery(artist: 'a', album: 'b')), isNull);
      expect(await DeezerCoverProvider(http).find(const CoverQuery(artist: 'a', album: 'b')), isNull);
    });
  });

  group('CoverService', () {
    late LibraryRepository repo;
    late FakeBridges bridges;
    late FakeHttpAdapter net;
    late Directory dir;
    late CoverService service;

    Future<void> setUpService(Map<String, Object> prefs) async {
      repo = await openTestRepo();
      bridges = FakeBridges();
      net = FakeHttpAdapter();
      dir = Directory.systemTemp.createTempSync('covers');
      final settings = await testSettings(prefs);
      final http = fakeHttp(net);
      service = CoverService(
        repo: repo,
        http: http,
        bridges: bridges,
        settings: settings,
        providers: {
          'caa': CoverArtArchiveProvider(http),
          'caa-group': CoverArtArchiveProvider(http, byReleaseGroup: true),
          'itunes': ITunesCoverProvider(http),
          'deezer': DeezerCoverProvider(http),
        },
        tagWriter: TagWriter(repo: repo, bridges: bridges),
        coversDir: () => dir,
        processor: (b) async => ImageProcessing.processCover(b),
      );
    }

    setUp(() => setUpService({}));
    tearDown(() async {
      await repo.appDb.close();
      dir.deleteSync(recursive: true);
    });

    Future<int> addAlbumTrack({String? releaseId, bool embedded = false}) async {
      final id = await repo.upsertTrack(TrackDraft(
        filePath: '/m/a/1.mp3',
        title: 'T',
        artist: 'Queen',
        album: 'A Night at the Opera',
        albumArtist: 'Queen',
        mbReleaseId: releaseId,
        hasEmbeddedArt: embedded,
        folder: '/m/a',
      ));
      return (await repo.trackById(id))!.albumId!;
    }

    test('chain order: Cover Art Archive first, and its image is cropped and cached', () async {
      final albumId = await addAlbumTrack(releaseId: releaseId);
      net.onFixture('coverartarchive.org/release/$releaseId', 'caa_index.json');
      net.on('coverartarchive.org/release/$releaseId/', (_) => FakeResponse('', bytes: makeImage(1600, 900)));
      final album = (await repo.albumById(albumId))!;
      final file = (await service.ensureAlbumCover(album))!;
      expect(file.existsSync(), isTrue);
      final d = ImageProcessing.dimensions(file.readAsBytesSync())!;
      expect(d.width, d.height);
      final saved = (await repo.albumById(albumId))!;
      expect(saved.coverPath, file.path);
      expect(saved.coverSource, 'caa');
      // second call is served from disk
      final before = net.requests.length;
      await service.ensureAlbumCover(saved);
      expect(net.requests.length, before);
    });

    test('falls through to iTunes when the release has no art anywhere else', () async {
      final albumId = await addAlbumTrack();
      net.on('coverartarchive.org', (_) => FakeResponse.notFound());
      net.onFixture('itunes.apple.com/search', 'itunes_album.json');
      net.on('mzstatic.com', (_) => FakeResponse('', bytes: makeImage(1200, 1200)));
      final f = await service.ensureAlbumCover((await repo.albumById(albumId))!);
      expect(f, isNotNull);
      expect((await repo.albumById(albumId))!.coverSource, 'itunes');
    });

    test('a failing provider does not stop the chain', () async {
      final albumId = await addAlbumTrack();
      net.on('itunes.apple.com', (_) => FakeResponse('boom', status: 500));
      net.onFixture('api.deezer.com/search/album', 'deezer_album_search.json');
      net.on('dzcdn.net', (_) => FakeResponse('', bytes: makeImage(1000, 1000)));
      final f = await service.ensureAlbumCover((await repo.albumById(albumId))!);
      expect(f, isNotNull);
      expect((await repo.albumById(albumId))!.coverSource, 'deezer');
    });

    test('nothing online: the embedded picture of a track is used', () async {
      final albumId = await addAlbumTrack(embedded: true);
      net.on('', (_) => FakeResponse.notFound());
      bridges.fakeTags.art['/m/a/1.mp3'] = true;
      // The fake extractor cannot write; emulate by pre-creating the raw file via a subclass-free trick:
      final t = (await repo.tracks(albumId: albumId)).single;
      File('${dir.path}/track_${t.id}.jpg').writeAsBytesSync(ImageProcessing.processCover(makeImage(640, 360)));
      final f = await service.ensureAlbumCover((await repo.albumById(albumId))!);
      expect(f, isNotNull);
      expect((await repo.albumById(albumId))!.coverSource, 'embedded');
    });

    test('no cover anywhere gives null (the UI draws a placeholder)', () async {
      final albumId = await addAlbumTrack();
      net.on('', (_) => FakeResponse.notFound());
      expect(await service.ensureAlbumCover((await repo.albumById(albumId))!), isNull);
    });

    test('concurrent requests for one album share a single fetch', () async {
      final albumId = await addAlbumTrack(releaseId: releaseId);
      net.onFixture('coverartarchive.org/release/$releaseId', 'caa_index.json');
      net.on('coverartarchive.org/release/$releaseId/', (_) => FakeResponse('', bytes: makeImage(800, 800)));
      final album = (await repo.albumById(albumId))!;
      final a = service.ensureAlbumCover(album);
      final b = service.ensureAlbumCover(album);
      expect(identical(a, b), isTrue);
      await a;
    });

    test('manual cover replaces the automatic one', () async {
      final albumId = await addAlbumTrack();
      final album = (await repo.albumById(albumId))!;
      final f = await service.setManual(album, makeImage(1000, 500));
      final saved = (await repo.albumById(albumId))!;
      expect(saved.coverSource, 'manual');
      expect(saved.coverPath, f.path);
    });

    test('embedInto writes the picture through the tag writer and remembers it', () async {
      await addAlbumTrack();
      final t = (await repo.tracks()).single;
      final cover = File('${dir.path}/c.jpg')..writeAsBytesSync(makeImage(300, 300));
      final outcome = await service.embedInto(t, cover);
      expect(outcome, TagWriteOutcome.written);
      expect(bridges.fakeTags.writes.single.update.artPath, cover.path);
      expect((await repo.trackById(t.id))!.hasEmbeddedArt, isTrue);
    });

    test('candidates from every provider are offered for manual picking', () async {
      net.onFixture('itunes.apple.com/search', 'itunes_album.json');
      net.onFixture('api.deezer.com/search/album', 'deezer_album_search.json');
      net.on('coverartarchive.org', (_) => FakeResponse.notFound());
      final c = await service.searchCandidates(const CoverQuery(artist: 'Queen', album: 'A Night at the Opera'));
      expect(c.map((e) => e.source).toSet(), containsAll(['itunes', 'deezer']));
    });
  });
}
