import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/core/library/library_repository.dart';
import 'package:musicplayer/core/models/track.dart';
import 'package:musicplayer/features/downloader/engines.dart';
import 'package:musicplayer/features/integrations/artist_info_service.dart';
import 'package:musicplayer/features/integrations/lastfm_client.dart';
import 'package:musicplayer/features/integrations/library_matcher.dart';
import 'package:musicplayer/features/integrations/listenbrainz_client.dart';
import 'package:musicplayer/features/integrations/metadata_clients.dart';
import 'package:musicplayer/features/integrations/playlist_importer.dart';
import 'package:musicplayer/features/integrations/radio_service.dart';
import 'package:musicplayer/features/integrations/release_watcher.dart';
import 'package:musicplayer/features/integrations/scrobble_service.dart';
import 'package:musicplayer/features/integrations/wishlist.dart';
import 'package:musicplayer/features/metadata/musicbrainz_client.dart';
import 'package:musicplayer/features/sources/direct_sources.dart';
import 'package:musicplayer/features/sources/podcast_radio.dart';
import 'package:musicplayer/features/sources/source_provider.dart';
import 'package:musicplayer/features/sources/unified_search.dart';
import 'package:musicplayer/features/sources/ytdlp_source.dart';
import 'package:musicplayer/platform/bridges.dart';

import 'helpers/fake_http.dart';
import 'helpers/fakes.dart';
import 'helpers/harness.dart';
import 'helpers/test_db.dart';

TrackDraft d(String path, String title, String artist, {String? album, int dur = 200000, String? mbArtist, String? genre}) =>
    TrackDraft(filePath: path, title: title, artist: artist, album: album, durationMs: dur, mbArtistId: mbArtist, genre: genre, folder: '/m');

const queenMbid = '0383dadf-2a4e-4d10-a46a-e9e041da8eb3';

void main() {
  group('Last.fm', () {
    test('signature = md5(sorted name+value pairs without format + secret)', () {
      final sig = LastFmClient.sign({'method': 'auth.getMobileSession', 'api_key': 'KEY', 'username': 'u', 'password': 'p', 'format': 'json'}, 'SECRET');
      final expected = md5.convert(utf8.encode('api_keyKEYmethodauth.getMobileSessionpasswordpusernameuSECRET')).toString();
      expect(sig, expected);
    });

    test('login posts a signed request and returns the session key', () async {
      final net = FakeHttpAdapter()..onFixture('ws.audioscrobbler.com', 'lastfm_session.json');
      final c = LastFmClient(fakeHttp(net), apiKey: () => 'KEY', apiSecret: () => 'SECRET', sessionKey: () => null);
      final s = await c.login('someuser', 'pw');
      expect(s.key, 'SESSIONKEY123');
      final body = net.requests.single.bodyText;
      expect(body, contains('method=auth.getMobileSession'));
      expect(body, contains('api_sig='));
      expect(body, contains('format=json'));
    });

    test('scrobble sends indexed array parameters, signed, at most 50', () async {
      final net = FakeHttpAdapter()..onFixture('ws.audioscrobbler.com', 'lastfm_scrobble.json');
      final c = LastFmClient(fakeHttp(net), apiKey: () => 'KEY', apiSecret: () => 'SECRET', sessionKey: () => 'SK');
      final n = await c.scrobble([
        for (var i = 0; i < 60; i++) ScrobbleItem(artist: 'A$i', title: 'T$i', timestamp: 1700000000 + i, album: 'Al', durationSec: 200),
      ]);
      expect(n, 2, reason: 'accepted count comes from the response');
      final body = Uri.splitQueryString(net.requests.single.bodyText);
      expect(body['artist[0]'], 'A0');
      expect(body['track[49]'], 'T49');
      expect(body.containsKey('artist[50]'), isFalse);
      expect(body['sk'], 'SK');
      expect(body['method'], 'track.scrobble');
      final params = Map.of(body)..remove('api_sig')..remove('format');
      expect(body['api_sig'], LastFmClient.sign(params, 'SECRET'));
    });

    test('errors become typed exceptions', () async {
      final net = FakeHttpAdapter()..onJson('ws.audioscrobbler.com', {'error': 9, 'message': 'Invalid session key'});
      final c = LastFmClient(fakeHttp(net), apiKey: () => 'K', apiSecret: () => 'S', sessionKey: () => 'SK');
      await expectLater(c.love('a', 't'), throwsA(isA<LastFmError>().having((e) => e.invalidSession, 'invalidSession', isTrue)));
      expect(LastFmError(29, 'x').retryable, isTrue);
    });

    test('similar tracks and artist bio parse; bio html link is stripped', () async {
      final net = FakeHttpAdapter()
        ..onFixture('track.getsimilar', 'lastfm_similar_tracks.json')
        ..onFixture('artist.getinfo', 'lastfm_artist_info.json');
      final c = LastFmClient(fakeHttp(net), apiKey: () => 'K', apiSecret: () => 'S', sessionKey: () => null);
      final sim = await c.similarTracks('Queen', 'Bohemian Rhapsody');
      expect(sim.first.title, 'Somebody to Love');
      expect(sim.first.match, 1.0);
      expect(sim.last.mbid, isNull);
      final info = (await c.artistInfo('Queen'))!;
      expect(info.bio, 'Queen are a British rock band formed in London in 1970.');
      expect(info.imageUrl, 'https://lastfm/img/mega.png');
      expect(info.tags, ['classic rock', 'rock']);
    });
  });

  group('ListenBrainz', () {
    test('submit builds the documented payload; single vs import', () async {
      final net = FakeHttpAdapter()..onJson('submit-listens', {'status': 'ok'});
      final c = ListenBrainzClient(fakeHttp(net), token: () => 'TOK');
      await c.submit([const ScrobbleItem(artist: 'A', title: 'T', timestamp: 1700000000, album: 'Al', durationSec: 200, mbid: 'rec1')]);
      final one = jsonDecode(net.requests.last.bodyText) as Map;
      expect(one['listen_type'], 'single');
      final meta = ((one['payload'] as List).single as Map);
      expect(meta['listened_at'], 1700000000);
      expect(meta['track_metadata']['artist_name'], 'A');
      expect(meta['track_metadata']['additional_info']['recording_mbid'], 'rec1');
      expect(meta['track_metadata']['additional_info']['duration_ms'], 200000);
      expect(net.requests.last.headers['Authorization'], 'Token TOK');
      await c.submit([const ScrobbleItem(artist: 'A', title: 'T', timestamp: 1), const ScrobbleItem(artist: 'B', title: 'U', timestamp: 2)]);
      expect(jsonDecode(net.requests.last.bodyText)['listen_type'], 'import');
    });

    test('playing_now has no listened_at', () async {
      final net = FakeHttpAdapter()..onJson('submit-listens', {'status': 'ok'});
      await ListenBrainzClient(fakeHttp(net), token: () => 'T').nowPlaying(const ScrobbleItem(artist: 'A', title: 'T', timestamp: 5));
      final body = jsonDecode(net.requests.single.bodyText) as Map;
      expect(body['listen_type'], 'playing_now');
      expect((body['payload'] as List).single.containsKey('listened_at'), isFalse);
    });

    test('validate reports the user, or null for a rejected token', () async {
      final ok = FakeHttpAdapter()..onJson('validate-token', {'valid': true, 'user_name': 'me'});
      expect(await ListenBrainzClient(fakeHttp(ok), token: () => 'T').validate(), 'me');
      final bad = FakeHttpAdapter()..onJson('validate-token', {'valid': false}, status: 200);
      expect(await ListenBrainzClient(fakeHttp(bad), token: () => 'T').validate(), isNull);
    });

    test('similar artists (recorded labs response)', () async {
      final net = FakeHttpAdapter()..onFixture('similar-artists/json', 'lb_similar_artists.json');
      final r = await ListenBrainzClient(fakeHttp(net), token: () => '').similarArtists(queenMbid);
      expect(r.first.name, 'David Bowie');
      expect(r.first.score, greaterThan(1000));
      expect(net.requests.single.uri.queryParameters['artist_mbids'], queenMbid);
    });
  });

  group('ScrobbleService', () {
    late LibraryRepository repo;
    late FakeHttpAdapter net;
    late ScrobbleService svc;
    var clock = DateTime(2026, 9, 24);

    Future<void> setUpService(Map<String, Object> prefs) async {
      repo = await openTestRepo();
      net = FakeHttpAdapter();
      final settings = await testSettings(prefs);
      final http = fakeHttp(net);
      svc = ScrobbleService(
        appDb: repo.appDb,
        settings: settings,
        lastFm: LastFmClient(http, apiKey: () => 'K', apiSecret: () => 'S', sessionKey: () => settings.lastFmSession),
        listenBrainz: ListenBrainzClient(http, token: () => settings.listenBrainzToken),
        now: () => clock,
      );
    }

    tearDown(() async {
      svc.dispose();
      await repo.appDb.close();
    });

    ScrobbleItem item(String t, {int? ts}) => ScrobbleItem(artist: 'A', title: t, timestamp: ts ?? clock.millisecondsSinceEpoch ~/ 1000 - 60);

    test('nothing is stored when no service is configured', () async {
      await setUpService({});
      await svc.record(item('x'));
      expect(await svc.pendingCount(), 0);
    });

    test('listens are queued offline and sent later; success clears the queue', () async {
      await setUpService({'key.lastfmSecret': 'S', 'key.lastfm': 'K', 'acc.lastfmSession': 'SK', 'key.lb': 'TOK'});
      net.on('', (_) => FakeResponse('offline', status: 500));
      await svc.record(item('one'));
      await svc.record(item('two'));
      var r = await svc.flush();
      expect(r.pending, 2, reason: 'server errors keep the rows');
      expect(r.errors, isNotEmpty);

      net.onFixture('ws.audioscrobbler.com', 'lastfm_scrobble.json');
      net.onJson('submit-listens', {'status': 'ok'});
      r = await svc.flush();
      expect(r.lastFm, 2);
      expect(r.listenBrainz, 2);
      expect(r.pending, 0);
    });

    test('a service that is off does not hold rows back', () async {
      await setUpService({'key.lb': 'TOK'}); // only ListenBrainz
      net.onJson('submit-listens', {'status': 'ok'});
      await svc.record(item('x'));
      final r = await svc.flush();
      expect(r.listenBrainz, 1);
      expect(r.pending, 0);
    });

    test('listens older than 14 days go to ListenBrainz only', () async {
      await setUpService({'key.lastfmSecret': 'S', 'key.lastfm': 'K', 'acc.lastfmSession': 'SK', 'key.lb': 'TOK'});
      net.onJson('submit-listens', {'status': 'ok'});
      net.onFixture('ws.audioscrobbler.com', 'lastfm_scrobble.json');
      await svc.record(item('old', ts: clock.subtract(const Duration(days: 30)).millisecondsSinceEpoch ~/ 1000));
      final r = await svc.flush();
      expect(r.lastFm, 0);
      expect(r.listenBrainz, 1);
      expect(net.requestsTo('ws.audioscrobbler.com'), isEmpty);
    });

    test('an expired Last.fm session is reported and cleared, queue kept', () async {
      await setUpService({'key.lastfmSecret': 'S', 'key.lastfm': 'K', 'acc.lastfmSession': 'SK'});
      net.onJson('ws.audioscrobbler.com', {'error': 9, 'message': 'Invalid session key'});
      await svc.record(item('x'));
      final r = await svc.flush();
      expect(r.errors.single, contains('sign in again'));
      expect(r.pending, 1);
      expect(svc.settings.lastFmSession, isNull);
    });

    test('batches of 50 are sent in timestamp order', () async {
      await setUpService({'key.lastfmSecret': 'S', 'key.lastfm': 'K', 'acc.lastfmSession': 'SK'});
      net.onFixture('ws.audioscrobbler.com', 'lastfm_scrobble.json');
      for (var i = 0; i < 120; i++) {
        await svc.record(item('t$i', ts: clock.millisecondsSinceEpoch ~/ 1000 - 5000 + i));
      }
      await svc.flush();
      final bodies = net.requestsTo('ws.audioscrobbler.com').map((r) => Uri.splitQueryString(r.bodyText)).toList();
      expect(bodies, hasLength(3));
      expect(bodies.first['track[0]'], 't0');
      expect(bodies[1]['track[0]'], 't50');
      expect(bodies[2].containsKey('track[20]'), isFalse);
    });

    test('now playing is best effort and never throws', () async {
      await setUpService({'key.lastfmSecret': 'S', 'key.lastfm': 'K', 'acc.lastfmSession': 'SK', 'key.lb': 'TOK'});
      net.on('', (_) => FakeResponse('boom', status: 500));
      await svc.nowPlaying(item('x'));
    });
  });

  group('LibraryMatcher', () {
    late LibraryRepository repo;
    late LibraryMatcher m;

    setUp(() async {
      repo = await openTestRepo();
      m = LibraryMatcher(repo);
      await repo.upsertTracks([
        d('/1.mp3', 'Yesterday', 'The Beatles', album: 'Help!'),
        d('/2.mp3', 'Bohemian Rhapsody', 'Queen', album: 'A Night at the Opera', dur: 354000),
        d('/3.mp3', 'Hey Jude', 'The Beatles'),
      ]);
    });
    tearDown(() => repo.appDb.close());

    test('canonical keys ignore remaster/feat suffixes and a leading "The"', () {
      expect(LibraryMatcher.titleKey('Yesterday - Remastered 2009'), 'yesterday');
      expect(LibraryMatcher.titleKey('Song (feat. Someone)'), 'song');
      expect(LibraryMatcher.titleKey('Song (Live at Wembley)'), 'song');
      expect(LibraryMatcher.artistKey('The Beatles'), 'beatles');
      expect(LibraryMatcher.artistKey('Artist A, Artist B'), 'artist a');
      expect(LibraryMatcher.titleKey('Rock (Remastered)'), 'rock');
    });

    test('matches across catalogues despite decoration differences', () async {
      expect((await m.find(artist: 'Beatles', title: 'Yesterday - Remastered 2009'))?.title, 'Yesterday');
      expect((await m.find(artist: 'Queen', title: 'Bohemian Rhapsody (Remastered 2011)', durationMs: 355000))?.artistName, 'Queen');
    });

    test('unknown songs and wrong artists do not match', () async {
      expect(await m.find(artist: 'Queen', title: 'Yesterday'), isNull);
      expect(await m.find(artist: 'Nobody', title: 'Nothing'), isNull);
    });
  });

  group('PlaylistImporter', () {
    late LibraryRepository repo;
    late PlaylistImporter imp;
    late FakeHttpAdapter net;

    Future<void> setUpImporter({Map<String, Object> prefs = const {}}) async {
      repo = await openTestRepo();
      net = FakeHttpAdapter();
      final settings = await testSettings(prefs);
      final http = fakeHttp(net);
      final bridges = FakeBridges();
      imp = PlaylistImporter(
        http: http,
        repo: repo,
        settings: settings,
        deezer: DeezerClient(http),
        engine: () => LocalYtDlpEngine(bridges.fakeYt, settings),
        wishlist: WishlistRepository(repo.appDb),
      );
      await repo.upsertTracks([d('/1.mp3', 'Song One', 'Artist A', album: 'Album X', dur: 200000)]);
    }

    setUp(() => setUpImporter());
    tearDown(() => repo.appDb.close());

    test('URL detection', () {
      expect(PlaylistImporter.spotifyId('https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M?si=abc'), '37i9dQZF1DXcBWIGoYBM5M');
      expect(PlaylistImporter.spotifyId('spotify:playlist:abc123'), 'abc123');
      expect(PlaylistImporter.deezerId('https://www.deezer.com/en/playlist/908622995'), '908622995');
      expect(PlaylistImporter.isYouTubePlaylist('https://www.youtube.com/playlist?list=PL123'), isTrue);
      expect(PlaylistImporter.isYouTubePlaylist('https://example.com'), isFalse);
    });

    test('Spotify: client-credentials token, then paged tracks; local/removed entries skipped', () async {
      await setUpImporter(prefs: {'key.spotifyId': 'ID', 'key.spotifySecret': 'SECRET'});
      net.onJson('accounts.spotify.com/api/token', {'access_token': 'TKN', 'expires_in': 3600});
      net.onJson('/v1/playlists/PL1?', {'name': 'My Mix'});
      net.onFixture('/v1/playlists/PL1/tracks', 'spotify_playlist.json');
      final p = await imp.fetch('https://open.spotify.com/playlist/PL1');
      expect(p.name, 'My Mix');
      expect(p.tracks, hasLength(2));
      expect(p.tracks.first.artist, 'Artist A, Artist B');
      expect(p.tracks.first.isrc, 'USABC1234567');
      final tokenReq = net.requestsTo('accounts.spotify.com').single;
      expect(tokenReq.headers['Authorization'], 'Basic ${base64.encode(utf8.encode('ID:SECRET'))}');
      expect(tokenReq.bodyText, contains('grant_type=client_credentials'));
    });

    test('Spotify without credentials explains what to do', () async {
      await expectLater(imp.fetch('https://open.spotify.com/playlist/PL1'), throwsA(isA<StateError>().having((e) => e.message, 'm', contains('client id'))));
    });

    test('plan splits into owned and missing; commit creates the playlist and wishlists the rest', () async {
      final playlist = const ImportedPlaylist(
        name: 'Mix',
        origin: 'spotify',
        tracks: [
          WishTrack(artist: 'Artist A', title: 'Song One - Remastered', durationMs: 201000),
          WishTrack(artist: 'Artist Z', title: 'Missing Song'),
        ],
      );
      final plan = await imp.plan(playlist);
      expect(plan.matched, hasLength(1));
      expect(plan.missing.single.title, 'Missing Song');
      final id = await imp.commit(plan);
      final p = (await repo.playlistById(id))!;
      expect(p.name, 'Mix');
      expect((await repo.playlistTracks(p)).single.title, 'Song One');
      final wishes = await imp.wishlist.all();
      expect(wishes.single.title, 'Missing Song');
      expect(wishes.single.origin, 'spotify');
      // committing again does not duplicate wishes
      await imp.commit(plan);
      expect(await imp.wishlist.all(), hasLength(1));
    });

    test('Deezer playlists need no credentials', () async {
      net.onJson('api.deezer.com/playlist/9', {
        'title': 'Deezer Mix',
        'tracks': {
          'data': [
            {'title': 'T1', 'duration': 180, 'artist': {'name': 'A1'}, 'album': {'title': 'Al'}},
          ]
        }
      });
      final p = await imp.fetch('https://www.deezer.com/en/playlist/9');
      expect(p.tracks.single.artist, 'A1');
      expect(p.tracks.single.durationMs, 180000);
    });

    test('unsupported links are rejected', () async {
      await expectLater(imp.fetch('https://example.org/x'), throwsA(isA<UnsupportedPlaylistUrl>()));
    });
  });

  group('WishlistDownloader.bestResult', () {
    RemoteTrack r(String title, String? artist, int? dur, {bool collection = false}) =>
        RemoteTrack(id: title, provider: 'yt', source: TrackSource.youtube, title: title, artist: artist, durationSec: dur, pageUrl: 'https://youtu.be/$title', isCollection: collection);

    test('prefers the matching title/artist/duration and rejects unrelated results', () {
      const wanted = WishTrack(artist: 'Queen', title: 'Bohemian Rhapsody', durationMs: 354000);
      final best = WishlistDownloader.bestResult(wanted, [
        r('Bohemian Rhapsody (Live Aid)', 'Queen', 1300),
        r('Bohemian Rhapsody', 'Queen', 355),
        r('Bohemian Rhapsody Cover', 'Someone', 300),
        r('Queen Greatest Hits', 'Queen', 3000, collection: true),
      ]);
      expect(best!.title, 'Bohemian Rhapsody');
      expect(WishlistDownloader.bestResult(wanted, [r('Totally different', 'Nobody', 100)]), isNull);
    });
  });

  group('RadioService', () {
    late LibraryRepository repo;
    late FakeHttpAdapter net;
    late RadioService radio;

    setUp(() async {
      repo = await openTestRepo();
      net = FakeHttpAdapter();
      final settings = await testSettings({'key.lastfm': 'K'});
      final http = fakeHttp(net);
      radio = RadioService(
        repo: repo,
        settings: settings,
        lastFm: LastFmClient(http, apiKey: () => settings.lastFmKey, apiSecret: () => '', sessionKey: () => null),
        listenBrainz: ListenBrainzClient(http, token: () => ''),
      );
      await repo.upsertTracks([
        d('/1.mp3', 'Bohemian Rhapsody', 'Queen', mbArtist: queenMbid, genre: 'Rock'),
        d('/2.mp3', 'Somebody to Love', 'Queen', genre: 'Rock'),
        d('/3.mp3', 'Other Rock Song', 'Some Band', genre: 'Rock'),
        d('/4.mp3', 'Jazz Tune', 'Miles', genre: 'Jazz'),
      ]);
    });
    tearDown(() => repo.appDb.close());

    test('follows Last.fm similar tracks: owned ones queue up, unowned become suggestions', () async {
      net.onFixture('track.getsimilar', 'lastfm_similar_tracks.json');
      net.onFixture('similar-artists', 'lb_similar_artists.json');
      final seed = (await repo.tracks(artistId: null)).firstWhere((t) => t.title == 'Bohemian Rhapsody');
      final plan = await radio.build(seed);
      expect(plan.local.first.id, seed.id, reason: 'the seed plays first');
      expect(plan.local.map((t) => t.title), contains('Somebody to Love'));
      expect(plan.suggestions.map((s) => s.title), contains('Stairway to Heaven'));
      expect(plan.basis, 'Last.fm similar tracks');
      expect(plan.local.map((t) => t.title), isNot(contains('Jazz Tune')));
    });

    test('with no service it still builds a station from the same artist and genre', () async {
      net.on('', (_) => FakeResponse('down', status: 500));
      final seed = (await repo.tracks()).firstWhere((t) => t.title == 'Bohemian Rhapsody');
      final plan = await radio.build(seed);
      expect(plan.basis, 'your library');
      expect(plan.local.map((t) => t.title).toSet(), containsAll(['Bohemian Rhapsody', 'Somebody to Love', 'Other Rock Song']));
      expect(plan.local.map((t) => t.title), isNot(contains('Jazz Tune')));
    });
  });

  group('ReleaseWatcher', () {
    MbReleaseGroup g(String date, {String type = 'Album', List<String> secondary = const []}) =>
        MbReleaseGroup(id: date, title: 'Album $date', primaryType: type, secondaryTypes: secondary, firstReleaseDate: date);

    test('isNewSince: full dates after the last check and not in the future', () {
      final last = DateTime(2026, 6, 15);
      final now = DateTime(2026, 9, 24);
      expect(ReleaseWatcher.isNewSince(g('2026-07-01'), last, now), isTrue);
      expect(ReleaseWatcher.isNewSince(g('2026-06-15'), last, now), isFalse);
      expect(ReleaseWatcher.isNewSince(g('2026-05-01'), last, now), isFalse);
      expect(ReleaseWatcher.isNewSince(g('2026-12-01'), last, now), isFalse, reason: 'announced, not out yet');
      expect(ReleaseWatcher.isNewSince(g('2026'), last, now), isFalse, reason: 'a bare year is too vague');
      expect(ReleaseWatcher.isNewSince(g('2026-08'), last, now), isTrue);
      expect(ReleaseWatcher.isNewSince(g('2026-06'), last, now), isFalse, reason: 'same month as the last check');
    });

    test('first check records a baseline, later checks alert once', () async {
      final repo = await openTestRepo();
      final net = FakeHttpAdapter();
      final bridges = FakeBridges();
      var now = DateTime(2026, 9, 24);
      final watcher = ReleaseWatcher(repo: repo, musicBrainz: MusicBrainzClient(fakeHttp(net)), system: bridges.fakeSystem, now: () => now);
      await repo.upsertTrack(d('/1.mp3', 'x', 'Queen', mbArtist: queenMbid));
      final artist = (await repo.artistByName('Queen'))!;
      await repo.updateArtist(artist.id, followed: true);
      net.onJson('/release-group', {
        'release-group-count': 3,
        'release-groups': [
          {'id': 'a', 'title': 'Old Album', 'primary-type': 'Album', 'secondary-types': [], 'first-release-date': '2020-01-01'},
          {'id': 'b', 'title': 'New Album', 'primary-type': 'Album', 'secondary-types': [], 'first-release-date': '2026-09-20'},
          {'id': 'c', 'title': 'Live Thing', 'primary-type': 'Album', 'secondary-types': ['Live'], 'first-release-date': '2026-09-21'},
        ],
      });
      var alerts = await watcher.checkAll();
      expect(alerts, isEmpty, reason: 'baseline');
      expect((await repo.artistById(artist.id))!.lastReleaseCheck, isNotNull);

      // pretend the baseline was taken on Sept 10
      await repo.updateArtist(artist.id, lastReleaseCheck: DateTime(2026, 9, 10).millisecondsSinceEpoch ~/ 1000);
      alerts = await watcher.checkAll();
      expect(alerts.map((a) => a.group.title), ['New Album'], reason: 'live albums are ignored');
      expect(bridges.fakeSystem.notifications.single.body, contains('New Album'));
      alerts = await watcher.checkAll();
      expect(alerts, isEmpty, reason: 'not alerted twice');
      await repo.appDb.close();
    });
  });

  group('ArtistInfoService', () {
    late LibraryRepository repo;
    late FakeHttpAdapter net;
    late ArtistInfoService svc;
    late Directory dir;

    setUp(() async {
      repo = await openTestRepo();
      net = FakeHttpAdapter();
      dir = Directory.systemTemp.createTempSync('artists');
      final http = fakeHttp(net);
      svc = ArtistInfoService(
        repo: repo,
        http: http,
        musicBrainz: MusicBrainzClient(http),
        fanart: FanartClient(http, apiKey: () => ''),
        audioDb: AudioDbClient(http, apiKey: () => '2'),
        wiki: WikiClient(http),
        deezer: DeezerClient(http),
        lastFm: LastFmClient(http, apiKey: () => '', apiSecret: () => '', sessionKey: () => null),
        imagesDir: () => dir,
        processor: (b) async => b,
      );
      await repo.upsertTrack(d('/1.mp3', 'Song', 'Queen'));
    });
    tearDown(() async {
      await repo.appDb.close();
      dir.deleteSync(recursive: true);
    });

    test('finds the MBID, takes the bio from TheAudioDB and downloads the photo', () async {
      net.onJson('/artist?', {
        'artists': [
          {'id': queenMbid, 'name': 'Queen', 'sort-name': 'Queen'}
        ]
      });
      net.onFixture('/artist/$queenMbid', 'mb_artist.json');
      // the free AudioDB key omits biographies in the recorded response: add one like a full key would
      final adb = fixtureJson('audiodb_artist.json') as Map;
      (adb['artists'] as List).first['strBiographyEN'] = 'Queen are a British rock band formed in London in 1970. ' * 3;
      net.onJson('theaudiodb.com/api', adb);
      net.on('r2.theaudiodb.com', (_) => FakeResponse('', bytes: jpegBytes(300, 300)));
      final a = (await repo.artistByName('Queen'))!;
      final r = await svc.refresh(a);
      expect(r.mbArtistId, queenMbid);
      expect(r.bio, isNotEmpty);
      expect(r.bioSource, 'TheAudioDB');
      expect(r.imagePath, isNotNull);
      expect(File(r.imagePath!).existsSync(), isTrue);
    });

    test('falls back to Wikipedia via the Wikidata link when AudioDB has nothing', () async {
      net.onJson('/artist?', {
        'artists': [
          {'id': queenMbid, 'name': 'Queen'}
        ]
      });
      net.onJson('/artist/$queenMbid', {
        'id': queenMbid,
        'name': 'Queen',
        'relations': [
          {'type': 'wikidata', 'url': {'resource': 'https://www.wikidata.org/wiki/Q15862'}}
        ]
      });
      net.on('theaudiodb.com', (_) => FakeResponse.json({'artists': null}));
      net.onFixture('wikidata.org/w/api.php', 'wikidata_entity.json');
      net.onFixture('wikipedia.org/api/rest_v1/page/summary/Queen_(band)', 'wiki_summary.json');
      net.on('upload.wikimedia.org', (_) => FakeResponse('', bytes: jpegBytes(200, 200)));
      net.on('commons.wikimedia.org', (_) => FakeResponse('', bytes: jpegBytes(200, 200)));
      final r = await svc.refresh((await repo.artistByName('Queen'))!);
      expect(r.bioSource, 'Wikipedia');
      expect(r.bio, contains('Queen'));
      expect(r.imagePath, isNotNull);
    });

    test('a fresh cache is not refetched', () async {
      net.onJson('/artist?', {'artists': []});
      net.on('', (_) => FakeResponse('{}'));
      final a = (await repo.artistByName('Queen'))!;
      await svc.refresh(a);
      final before = net.requests.length;
      await svc.refresh((await repo.artistByName('Queen'))!);
      // no bio/image found the first time, so it may retry - but a complete record must not
      await repo.updateArtist(a.id, bio: 'x' * 80, imagePath: '${dir.path}/exists.jpg');
      File('${dir.path}/exists.jpg').writeAsBytesSync([1]);
      final n = net.requests.length;
      await svc.refresh((await repo.artistByName('Queen'))!);
      expect(net.requests.length, n);
      expect(n, greaterThanOrEqualTo(before));
    });

    test('links come from MusicBrainz relations', () async {
      net.onFixture('/artist/$queenMbid', 'mb_artist.json');
      final a = (await repo.artistByName('Queen'))!;
      await repo.updateArtist(a.id, mbArtistId: queenMbid);
      final links = await svc.links((await repo.artistByName('Queen'))!);
      expect(links.official, contains('queenonline'));
      expect(links.links['discogs'], contains('discogs'));
    });

    test('discography separates owned studio albums from missing ones', () async {
      final a = (await repo.artistByName('Queen'))!;
      await repo.updateArtist(a.id, mbArtistId: queenMbid);
      await repo.upsertTrack(d('/2.mp3', 'x', 'Queen', album: 'A Night at the Opera'));
      net.onJson('/release-group', {
        'release-group-count': 3,
        'release-groups': [
          {'id': '1', 'title': 'A Night at the Opera', 'primary-type': 'Album', 'secondary-types': [], 'first-release-date': '1975-11-21'},
          {'id': '2', 'title': 'News of the World', 'primary-type': 'Album', 'secondary-types': [], 'first-release-date': '1977-10-28'},
          {'id': '3', 'title': 'Greatest Hits', 'primary-type': 'Album', 'secondary-types': ['Compilation'], 'first-release-date': '1981-10-26'},
        ],
      });
      final r = await svc.discography((await repo.artistByName('Queen'))!);
      expect(r.owned.map((g) => g.title), ['A Night at the Opera']);
      expect(r.missing.map((g) => g.title), ['News of the World']);
    });
  });

  group('metadata clients (recorded responses)', () {
    test('Deezer artist search, fanart ordering, Discogs release credits, Wikipedia summary', () async {
      final net = FakeHttpAdapter()
        ..onFixture('api.deezer.com/search/artist', 'deezer_artist_search.json')
        ..onFixture('fanart.tv', 'fanart_artist.json')
        ..onFixture('api.discogs.com/database/search', 'discogs_search.json')
        ..onFixture('api.discogs.com/releases/1234', 'discogs_release.json')
        ..onFixture('rest_v1/page/summary', 'wiki_summary.json');
      final http = fakeHttp(net);
      final dz = await DeezerClient(http).findArtist('Queen(Ares)');
      expect(dz!.pictureXl, contains('dzcdn'));
      expect(await FanartClient(http, apiKey: () => '').artistThumb(queenMbid), isNull);
      final fan = FanartClient(http, apiKey: () => 'KEY');
      expect(await fan.artistThumb(queenMbid), endsWith('queen-2.jpg'), reason: 'most liked first');
      expect(await fan.logo(queenMbid), endsWith('.png'));
      final discogs = DiscogsClient(http, token: () => 'T');
      final id = await discogs.findRelease(artist: 'Queen', album: 'A Night At The Opera');
      expect(id, 1234);
      final rel = (await discogs.release(id!))!;
      expect(rel.styles, contains('Prog Rock'));
      expect(rel.credits['Producer'], ['Roy Thomas Baker']);
      expect(net.requestsTo('api.discogs.com').first.headers['Authorization'], 'Discogs token=T');
      final wiki = (await WikiClient(http).summary('Queen (band)'))!;
      expect(wiki.extract, isNotEmpty);
      expect(WikiClient.wikidataId('https://www.wikidata.org/wiki/Q15862'), 'Q15862');
      expect(WikiClient.commonsUrl('Queen 1984.jpg'), contains('Special:FilePath/Queen_1984.jpg'));
    });
  });

  group('podcasts', () {
    test('RSS feed parsing: channel, episodes, durations, dates, enclosures', () {
      final r = PodcastService.parseFeed(fixture('podcast_feed.xml'), 'https://feed.example/rss');
      expect(r.feed.title, 'Test Cast');
      expect(r.feed.author, 'The Tester');
      expect(r.feed.imageUrl, 'https://cdn.example/cast.jpg');
      expect(r.episodes, hasLength(2), reason: 'items without an enclosure are skipped');
      final e = r.episodes.first;
      expect(e.title, 'Episode 2: Mocks');
      expect(e.audioUrl, 'https://cdn.example/ep2.mp3');
      expect(e.duration, const Duration(hours: 1, minutes: 2, seconds: 3));
      expect(e.published, DateTime.utc(2002, 10, 2, 11, 0), reason: '+0200 converted to UTC');
      expect(e.imageUrl, 'https://cdn.example/ep2.jpg');
      expect(e.sizeBytes, 12345678);
      final second = r.episodes.last;
      expect(second.duration, const Duration(seconds: 2710));
      expect(second.imageUrl, 'https://cdn.example/cast.jpg', reason: 'falls back to the show artwork');
      final item = e.toMediaItem();
      expect(item.extras!['isPodcast'], isTrue);
      expect(item.id, e.audioUrl);
      expect(e.toRemoteTrack().downloadUrl, e.audioUrl);
    });

    test('duration and date helpers', () {
      expect(PodcastService.parseItunesDuration('45:10'), const Duration(minutes: 45, seconds: 10));
      expect(PodcastService.parseItunesDuration('90'), const Duration(seconds: 90));
      expect(PodcastService.parseItunesDuration('x'), isNull);
      expect(PodcastService.parseRfc822('02 Oct 2002 13:00:00 GMT'), DateTime.utc(2002, 10, 2, 13));
      expect(PodcastService.parseRfc822('garbage'), isNull);
    });

    test('iTunes search works without keys; subscriptions persist', () async {
      final repo = await openTestRepo();
      final net = FakeHttpAdapter()..onFixture('itunes.apple.com/search', 'itunes_podcast.json');
      final svc = PodcastService(http: fakeHttp(net), appDb: repo.appDb, settings: await testSettings());
      final feeds = await svc.search('npr');
      expect(feeds.first.feedUrl, 'https://feeds.npr.org/500005/podcast.xml');
      expect(feeds.first.author, 'NPR');
      await svc.subscribe(feeds.first);
      expect(await svc.isSubscribed(feeds.first.feedUrl), isTrue);
      expect((await svc.subscriptions()).single.title, feeds.first.title);
      await svc.unsubscribe(feeds.first.feedUrl);
      expect(await svc.subscriptions(), isEmpty);
      await repo.appDb.close();
    });

    test('Podcast Index requests are authenticated with the key/secret hash', () async {
      final repo = await openTestRepo();
      final net = FakeHttpAdapter()..onJson('podcastindex.org', {'feeds': [{'title': 'PI Show', 'url': 'https://pi/feed', 'author': 'A', 'image': 'https://pi/i.jpg'}]});
      final svc = PodcastService(
        http: fakeHttp(net),
        appDb: repo.appDb,
        settings: await testSettings({'key.pi': 'KEY', 'key.piSecret': 'SEC'}),
        now: () => DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
      final feeds = await svc.search('x');
      expect(feeds.single.title, 'PI Show');
      final h = net.requests.single.headers;
      expect(h['X-Auth-Key'], 'KEY');
      expect(h['X-Auth-Date'], '1700000000');
      expect(h['Authorization'], sha1.convert(utf8.encode('KEYSEC1700000000')).toString());
      await repo.appDb.close();
    });
  });

  group('radio browser', () {
    test('discovers a server, searches, maps stations to queue items, keeps favourites', () async {
      final repo = await openTestRepo();
      final net = FakeHttpAdapter()
        ..onFixture('all.api.radio-browser.info/json/servers', 'radio_servers.json')
        ..onFixture('/json/stations/search', 'radio_search.json');
      final rb = RadioBrowserClient(fakeHttp(net), repo.appDb);
      final stations = await rb.search(name: 'jazz');
      expect(stations, isNotEmpty);
      expect(net.requestsTo('/json/stations/search').single.uri.host, 'de1.api.radio-browser.info');
      final s = stations.first;
      final item = s.toMediaItem();
      expect(item.extras!['isRadio'], isTrue);
      expect(item.id, s.url);
      await rb.addFavorite(s);
      expect(await rb.isFavorite(s.url), isTrue);
      expect((await rb.favorites()).single.name, s.name);
      await rb.removeFavorite(s.url);
      expect(await rb.favorites(), isEmpty);
      await repo.appDb.close();
    });

    test('falls back to the default server when discovery fails', () async {
      final repo = await openTestRepo();
      final net = FakeHttpAdapter()
        ..on('all.api.radio-browser.info', (_) => FakeResponse('x', status: 500))
        ..onFixture('/json/stations/search', 'radio_search.json');
      await RadioBrowserClient(fakeHttp(net), repo.appDb).search(name: 'x');
      expect(net.requestsTo('/json/stations/search').single.uri.host, 'de1.api.radio-browser.info');
      await repo.appDb.close();
    });
  });

  group('yt-dlp search source + unified search', () {
    late Harness h;
    setUp(() async => h = await Harness.create());
    tearDown(() => h.dispose());

    Map<String, dynamic> flat(List<Map<String, dynamic>> entries, {String title = 'Results'}) => {'_type': 'playlist', 'title': title, 'entries': entries};

    test('YouTube search uses ytsearchN: and returns playable results', () async {
      h.bridges.fakeYt.onRun = (args) => YtDlpResult(
            exitCode: 0,
            out: jsonEncode(flat([
              {'id': 'a', 'title': 'Song A', 'uploader': 'Chan', 'duration': 200, 'url': 'https://www.youtube.com/watch?v=a', 'thumbnails': [{'url': 'https://t/a.jpg'}]},
              {'id': 'b', 'title': 'Song B', 'url': 'https://www.youtube.com/watch?v=b'},
            ])),
            err: '',
          );
      final src = ytDlpProviders(() => h.router.current).firstWhere((p) => p.id == 'youtube');
      final r = await src.search('daft punk', limit: 7);
      expect(h.bridges.fakeYt.runs.single.last, 'ytsearch7:daft punk');
      expect(r.map((e) => e.title), ['Song A', 'Song B']);
      expect(r.first.pageUrl, 'https://www.youtube.com/watch?v=a');
      expect(r.first.thumbnail, 'https://t/a.jpg');
      expect(r.first.toMediaItem().extras!['resolveUrl'], 'https://www.youtube.com/watch?v=a');
    });

    test('Bandcamp has no search; playlists expand with track numbers', () async {
      final providers = ytDlpProviders(() => h.router.current);
      expect(providers.firstWhere((p) => p.id == 'bandcamp').supportsSearch, isFalse);
      h.bridges.fakeYt.onRun = (args) => YtDlpResult(
            exitCode: 0,
            out: jsonEncode(flat([
              {'id': '1', 'title': 'One', 'url': 'https://a.bandcamp.com/track/one'},
              {'id': '2', 'title': 'Two', 'url': 'https://a.bandcamp.com/track/two'},
            ], title: 'The Album')),
            err: '',
          );
      const album = RemoteTrack(id: 'x', provider: 'bandcamp', source: TrackSource.bandcamp, title: 'The Album', pageUrl: 'https://a.bandcamp.com/album/x', isCollection: true);
      final tracks = await providers.firstWhere((p) => p.id == 'bandcamp').expand(album);
      expect(tracks.map((t) => t.trackNumber), [1, 2]);
      expect(tracks.first.album, 'The Album');
    });

    test('an engine failure is reported by the section, not thrown', () async {
      h.bridges.fakeYt.onRun = (_) => const YtDlpResult(exitCode: 1, out: '', err: 'ERROR: Unable to download webpage: timed out');
      final registry = SourceRegistry(h.settings, ytDlpProviders(() => h.router.current));
      final search = UnifiedSearch(repo: h.repo, settings: h.settings, registry: registry);
      await h.repo.upsertTrack(TrackDraft(filePath: '/m/a.mp3', title: 'Local Song', artist: 'Someone', folder: '/m'));
      final updates = await search.search('local').toList();
      final last = updates.last;
      expect(last.first.id, 'local');
      expect(last.first.tracks.single.title, 'Local Song');
      final yt = last.firstWhere((s) => s.id == 'youtube');
      expect(yt.status, SectionStatus.failed);
      expect(yt.error, isNotNull);
      expect(updates.first.length, 1, reason: 'local results arrive before any remote source answers');
    });

    test('unified search fills each provider independently and honours the source switches', () async {
      await h.settings.setDisabledSources(['soundcloud', 'bandcamp', 'mixcloud', 'vimeo', 'twitch', 'ytdlp-other', 'youtubemusic']);
      h.bridges.fakeYt.onRun = (args) => YtDlpResult(exitCode: 0, out: jsonEncode(flat([{'id': 'a', 'title': 'Remote', 'url': 'https://www.youtube.com/watch?v=a'}])), err: '');
      h.net.onFixture('advancedsearch.php', 'ia_search.json');
      final registry = SourceRegistry(h.settings, [...ytDlpProviders(() => h.router.current), InternetArchiveSource(h.http)]);
      final updates = await UnifiedSearch(repo: h.repo, settings: h.settings, registry: registry).search('anything').toList();
      final sections = updates.last;
      expect(sections.map((s) => s.id), ['local', 'youtube', 'archive']);
      expect(sections.every((s) => s.status == SectionStatus.done), isTrue);
      expect(sections.firstWhere((s) => s.id == 'archive').remote, hasLength(3));
      expect(sections.firstWhere((s) => s.id == 'youtube').remote.single.title, 'Remote');
    });

    test('a blank query returns nothing', () async {
      final registry = SourceRegistry(h.settings, const []);
      expect(await UnifiedSearch(repo: h.repo, settings: h.settings, registry: registry).search('  ').toList(), [<SearchSection>[]]);
    });
  });
}
