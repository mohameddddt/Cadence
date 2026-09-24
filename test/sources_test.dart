import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/core/models/track.dart';
import 'package:musicplayer/core/net/http_service.dart';
import 'package:musicplayer/features/downloader/source_detect.dart';
import 'package:musicplayer/features/sources/direct_sources.dart';
import 'package:musicplayer/features/sources/source_provider.dart';

import 'helpers/fake_http.dart';
import 'helpers/fakes.dart';

void main() {
  group('HttpService.buildUri', () {
    test('list values repeat the key, existing query is kept, nulls are skipped', () {
      final u = HttpService.buildUri('https://x.test/a?keep=1', {
        'fl[]': ['id', 'title'],
        'rows': 5,
        'skip': null,
      });
      expect(u.queryParametersAll['fl[]'], ['id', 'title']);
      expect(u.queryParameters['rows'], '5');
      expect(u.queryParameters['keep'], '1');
      expect(u.queryParameters.containsKey('skip'), isFalse);
    });

    test('no parameters leaves a clean URL', () {
      expect(HttpService.buildUri('https://x.test/a', null).toString(), 'https://x.test/a');
    });
  });

  group('InternetArchiveSource', () {
    test('search parses items and sends repeated fl[] fields', () async {
      final net = FakeHttpAdapter()..onFixture('advancedsearch.php', 'ia_search.json');
      final results = await InternetArchiveSource(fakeHttp(net)).search('grateful dead');
      expect(results, hasLength(3));
      expect(results.first.pageUrl, 'https://archive.org/details/OtherBrothersFox4.8');
      expect(results.first.isCollection, isTrue);
      expect(results.first.artist, 'The Other Brothers');
      final q = net.requests.single.uri;
      expect(q.queryParametersAll['fl[]'], containsAll(['identifier', 'title', 'creator']));
      expect(q.queryParameters['q'], contains('mediatype:audio'));
    });

    test('an item expands to one song per track, preferring MP3 by default', () async {
      final net = FakeHttpAdapter()..onFixture('/metadata/OtherBrothersFox4.8', 'ia_metadata.json');
      final src = InternetArchiveSource(fakeHttp(net));
      const item = RemoteTrack(id: 'OtherBrothersFox4.8', provider: 'archive', source: TrackSource.internetArchive, title: 'Fox', pageUrl: 'https://archive.org/details/OtherBrothersFox4.8', isCollection: true);
      final tracks = await src.expand(item);
      expect(tracks.length, greaterThanOrEqualTo(5));
      expect(tracks.first.title, 'Intro');
      expect(tracks.first.format, 'VBR MP3');
      expect(tracks.first.downloadUrl, 'https://archive.org/download/OtherBrothersFox4.8/01-Intro.mp3');
      expect(tracks.first.trackNumber, 1);
      expect(tracks.first.durationSec, 53);
      expect(tracks.map((t) => t.trackNumber), orderedEquals(tracks.map((t) => t.trackNumber).toList()..sort()));
      expect(tracks.every((t) => t.isDirect), isTrue);
      expect(tracks[1].downloadUrl, contains('Don%27t') .or(contains("Don't")));
    });

    test('lossless preference picks FLAC when available', () async {
      final net = FakeHttpAdapter()..onFixture('/metadata/', 'ia_metadata.json');
      final src = InternetArchiveSource(fakeHttp(net), preferLossless: true);
      const item = RemoteTrack(id: 'OtherBrothersFox4.8', provider: 'archive', source: TrackSource.internetArchive, title: 'Fox', pageUrl: 'u', isCollection: true);
      final tracks = await src.expand(item);
      expect(tracks.first.format, 'Flac');
      expect(tracks.first.downloadUrl, endsWith('.flac'));
    });

    test('resolves an archive.org URL to an item and handles unknown ids', () async {
      final net = FakeHttpAdapter()..onFixture('/metadata/OtherBrothersFox4.8', 'ia_metadata.json');
      final r = await InternetArchiveSource(fakeHttp(net)).resolve('https://archive.org/download/OtherBrothersFox4.8/01-Intro.mp3');
      expect(r!.isCollection, isTrue);
      expect(r.pageUrl, 'https://archive.org/details/OtherBrothersFox4.8');
      final none = FakeHttpAdapter()..on('/metadata/', (_) => FakeResponse.notFound());
      expect(await InternetArchiveSource(fakeHttp(none)).resolve('https://archive.org/details/nope'), isNull);
    });
  });

  group('AudiusSource', () {
    test('discovers a host, searches and builds stream/download URLs', () async {
      final net = FakeHttpAdapter()
        ..onFixture('api.audius.co/v1/tracks/search', 'audius_search.json')
        ..onFixture('https://api.audius.co', 'audius_hosts.json');
      // both routes match the search URL; the more specific one was registered first, so re-register
      net.onFixture('/v1/tracks/search', 'audius_search.json');
      final results = await AudiusSource(fakeHttp(net)).search('piano');
      expect(results, isNotEmpty);
      final t = results.first;
      expect(t.title, 'Piano Fala');
      expect(t.artist, 'wn6');
      expect(t.durationSec, 76);
      expect(t.streamUrl, startsWith('https://api.audius.co/v1/tracks/'));
      expect(t.streamUrl, contains('app_name=musicplayer'));
      expect(t.thumbnail, contains('480x480'));
      expect(t.pageUrl, 'https://audius.co/wn6/piano-fala');
      expect(t.source, TrackSource.audius);
    });
  });

  group('JamendoSource', () {
    const sample = {
      'results': [
        {
          'id': '1',
          'name': 'Song',
          'artist_name': 'Band',
          'album_name': 'Album',
          'duration': 200,
          'audio': 'https://mp3l.jamendo.com/x.mp3',
          'audiodownload': 'https://mp3d.jamendo.com/x.mp3',
          'audiodownload_allowed': true,
          'image': 'https://img/1.jpg',
          'license_ccurl': 'https://creativecommons.org/licenses/by/3.0/',
          'shareurl': 'https://www.jamendo.com/track/1',
          'releasedate': '2019-04-01',
        },
        {'id': '2', 'name': 'NoDownload', 'audio': 'https://s', 'audiodownload_allowed': false},
      ]
    };

    test('parses tracks, honours the download flag', () async {
      final net = FakeHttpAdapter()..onJson('api.jamendo.com', sample);
      final r = await JamendoSource(fakeHttp(net), clientId: () => 'CID').search('x');
      expect(r.first.downloadUrl, 'https://mp3d.jamendo.com/x.mp3');
      expect(r.first.year, 2019);
      expect(r.first.license, contains('creativecommons'));
      expect(r.last.downloadUrl, isNull);
      expect(net.requests.single.uri.queryParameters['client_id'], 'CID');
    });

    test('is inert without a client id', () async {
      final net = FakeHttpAdapter();
      expect(await JamendoSource(fakeHttp(net), clientId: () => '').search('x'), isEmpty);
      expect(net.requests, isEmpty);
    });
  });

  group('CcMixterSource', () {
    test('parses uploads and picks the mp3 file', () async {
      final net = FakeHttpAdapter()..onFixture('ccmixter.org/api/query', 'ccmixter.json');
      final r = await CcMixterSource(fakeHttp(net)).search('piano');
      expect(r, isNotEmpty);
      expect(r.first.format, 'MP3');
      expect(r.first.downloadUrl, endsWith('.mp3'));
      expect(r.first.artist, 'matthew_c_wright');
      expect(r.first.durationSec, 178);
      expect(r.first.license, startsWith('https://creativecommons.org'));
    });
  });

  group('DirectFileSource', () {
    test('titles the track after the file and downloads the URL as is', () async {
      final r = await DirectFileSource().resolve('https://cdn.example.org/audio/My_Great%20Song.mp3?sig=1');
      expect(r!.title, 'My Great Song');
      expect(r.isDirect, isTrue);
      expect(r.downloadUrl, 'https://cdn.example.org/audio/My_Great%20Song.mp3?sig=1');
      expect(r.isCollection, isFalse);
    });

    test('is picked for audio-file links only', () async {
      final settings = await testSettings({});
      final registry = SourceRegistry(settings, [DirectFileSource()]);
      expect(registry.forUrl(detectSource('http://nas.local/music/a.flac'))?.id, 'directfile');
      expect(registry.forUrl(detectSource('https://example.org/page')), isNull);
    });
  });

  group('SourceRegistry', () {
    test('respects the per-source switches in settings', () async {
      final settings = await testSettings({'src.disabled': ['audius']});
      final http = fakeHttp(FakeHttpAdapter());
      final registry = SourceRegistry(settings, [AudiusSource(http), InternetArchiveSource(http)]);
      expect(registry.enabled.map((p) => p.id), ['archive']);
      expect(registry.byId('audius'), isNotNull);
      expect(registry.forUrl(detectSource('https://archive.org/details/foo'))?.id, 'archive');
      expect(registry.forUrl(detectSource('https://audius.co/a/b')), isNull, reason: 'disabled');
    });
  });

  test('RemoteTrack queue items stream directly or through yt-dlp resolution', () {
    const direct = RemoteTrack(id: '1', provider: 'archive', source: TrackSource.internetArchive, title: 'T', pageUrl: 'https://archive.org/details/x', streamUrl: 'https://archive.org/download/x/a.mp3');
    expect(direct.toMediaItem().id, 'https://archive.org/download/x/a.mp3');
    expect(direct.toMediaItem().extras!['resolveUrl'], isNull);
    const page = RemoteTrack(id: '2', provider: 'ytdlp', source: TrackSource.youtube, title: 'T', pageUrl: 'https://www.youtube.com/watch?v=x');
    expect(page.toMediaItem().extras!['resolveUrl'], 'https://www.youtube.com/watch?v=x');
    expect(page.toMediaItem().extras!['remote'], isTrue);
  });
}

extension on Matcher {
  Matcher or(Matcher other) => anyOf(this, other);
}
