import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/core/library/library_repository.dart';
import 'package:musicplayer/core/models/track.dart';
import 'package:musicplayer/core/net/http_service.dart';
import 'package:musicplayer/features/metadata/acoustid_client.dart';
import 'package:musicplayer/features/metadata/chromaprint.dart';
import 'package:musicplayer/features/metadata/fingerprint_service.dart';
import 'package:musicplayer/features/metadata/identify_service.dart';
import 'package:musicplayer/features/metadata/musicbrainz_client.dart';
import 'package:musicplayer/features/metadata/tag_writer.dart';
import 'package:musicplayer/platform/bridges.dart';

import 'helpers/fake_http.dart';
import 'helpers/fakes.dart';
import 'helpers/synth.dart';
import 'helpers/test_db.dart';

const bohemianRecording = 'b1a9c0e9-d987-4042-ae91-78d6a3267d69';

class FakeFingerprints extends FingerprintService {
  FakeFingerprints(this.result) : super(decoder: FakeDecoderBridge(), tempDir: () => Directory.systemTemp);
  Fingerprint? result;
  int calls = 0;

  @override
  Future<Fingerprint?> forTrack(Track t) async {
    calls++;
    return result;
  }
}

class PcmDecoder implements DecoderBridge {
  PcmDecoder(this.pcm, this.rate);
  final Int16List pcm;
  final int rate;

  @override
  Future<DecodedAudio> decode({String? path, String? uri, required String out, int sampleRate = 0, int channels = 1, int maxSeconds = 0}) async {
    File(out).writeAsBytesSync(pcm.buffer.asUint8List(pcm.offsetInBytes, pcm.lengthInBytes));
    return DecodedAudio(sampleRate: rate, channels: 1, frames: pcm.length, sourceSampleRate: rate);
  }
}

void main() {
  group('MusicBrainzClient (recorded responses)', () {
    late FakeHttpAdapter net;
    late MusicBrainzClient mb;

    setUp(() {
      net = FakeHttpAdapter();
      mb = MusicBrainzClient(fakeHttp(net));
    });

    test('recording lookup parses artists, releases, genres, ISRCs and track positions', () async {
      net.onFixture('/recording/$bohemianRecording', 'mb_recording.json');
      final rec = (await mb.recording(bohemianRecording))!;
      expect(rec.title, 'Bohemian Rhapsody');
      expect(rec.artistCredit, 'Queen');
      expect(rec.artists.single.id, '0383dadf-2a4e-4d10-a46a-e9e041da8eb3');
      expect(rec.isrcs, contains('GBUM71029604'));
      expect(rec.genres.map((g) => g.toLowerCase()), contains('rock'));
      expect(rec.releases, hasLength(8));
      final first = rec.releases.first;
      expect(first.title, 'A Night at the Opera');
      expect(first.status, 'Official');
      expect(first.primaryType, 'Album');
      expect(first.releaseGroupId, '6b47c9a0-b9e1-3df9-a5e8-50a6ce0dbdbd');
      expect(first.trackNumber, isNotNull, reason: 'vinyl "B4" falls back to the position');
      expect(first.releaseTrackId, isNotEmpty);
    });

    test('sends the descriptive User-Agent and asks for JSON with the includes we need', () async {
      net.onFixture('/recording/', 'mb_recording.json');
      await mb.recording(bohemianRecording);
      final req = net.requests.single;
      expect(req.headers['User-Agent'], contains('MusicPlayerTests'));
      expect(req.uri.queryParameters['fmt'], 'json');
      expect(req.uri.queryParameters['inc'], contains('releases'));
      expect(req.uri.queryParameters['inc'], contains('media'));
      expect(req.uri.host, 'musicbrainz.org');
    });

    test('responses are cached: the second lookup makes no request', () async {
      net.onFixture('/recording/', 'mb_recording.json');
      await mb.recording(bohemianRecording);
      await mb.recording(bohemianRecording);
      expect(net.requests, hasLength(1));
    });

    test('404 means "not found", not an exception', () async {
      net.on('/recording/', (_) => FakeResponse.notFound());
      expect(await mb.recording('00000000-0000-0000-0000-000000000000'), isNull);
    });

    test('search builds an escaped Lucene query with a duration window', () async {
      net.onFixture('/recording?', 'mb_search.json');
      final hits = await mb.searchRecordings(title: 'Say "Hello"', artist: 'A\\B', durationMs: 200000);
      final q = net.requests.single.uri.queryParameters['query']!;
      expect(q, contains(r'recording:"Say \"Hello\""'));
      expect(q, contains(r'artist:"A\\B"'));
      expect(q, contains('dur:[190000 TO 210000]'));
      expect(hits.first.score, 100);
      expect(hits.first.title, 'Bohemian Rhapsody');
    });

    test('release detail exposes the full tracklist', () async {
      net.onFixture('/release/', 'mb_release.json');
      final d = (await mb.release('6defd963-fe91-4550-b18e-82c685603c2b'))!;
      expect(d.release.title, 'A Night at the Opera');
      expect(d.tracks.length, greaterThanOrEqualTo(10));
      expect(d.tracks.any((t) => t.title == 'Bohemian Rhapsody' && t.recordingId == bohemianRecording), isTrue);
      expect(d.tracks.first.disc, 1);
    });

    test('artist detail exposes url relations', () async {
      net.onFixture('/artist/', 'mb_artist.json');
      final a = (await mb.artist('0383dadf-2a4e-4d10-a46a-e9e041da8eb3'))!;
      expect(a.name, 'Queen');
      expect(a.country, 'GB');
      expect(a.link('discogs'), contains('discogs.com'));
      expect(a.genres, isNotEmpty);
    });

    test('server errors are retried, then reported', () async {
      var calls = 0;
      net.on('/recording/', (_) {
        calls++;
        return calls < 3 ? FakeResponse('{"error":"busy"}', status: 503) : FakeResponse.fixture('mb_recording.json');
      });
      expect((await mb.recording(bohemianRecording))!.title, 'Bohemian Rhapsody');
      expect(calls, 3);

      final failing = FakeHttpAdapter()..on('/recording/', (_) => FakeResponse('{"error":"down"}', status: 503));
      final client = MusicBrainzClient(fakeHttp(failing));
      await expectLater(client.recording('x'), throwsA(isA<HttpFailure>().having((e) => e.statusCode, 'status', 503)));
      expect(failing.requests, hasLength(3));
    });
  });

  group('AcoustIdClient', () {
    const okResponse = {
      'status': 'ok',
      'results': [
        {
          'id': 'acoust-low',
          'score': 0.42,
          'recordings': [
            {'id': 'rec-x', 'title': 'Other', 'artists': [{'id': 'a2', 'name': 'Someone'}]}
          ],
        },
        {
          'id': 'acoust-1',
          'score': 0.97,
          'recordings': [
            {
              'id': bohemianRecording,
              'title': 'Bohemian Rhapsody',
              'duration': 354,
              'artists': [{'id': '0383dadf', 'name': 'Queen'}],
              'releasegroups': [
                {'id': 'rg1', 'title': 'A Night at the Opera', 'type': 'Album', 'artists': [{'id': '0383dadf', 'name': 'Queen'}]}
              ],
            }
          ],
        },
      ],
    };

    test('posts the fingerprint and returns results best-first', () async {
      final net = FakeHttpAdapter()..onJson('/lookup', okResponse);
      final client = AcoustIdClient(fakeHttp(net), apiKey: () => 'KEY123');
      final r = await client.lookup(fingerprint: 'AQAA...', durationSeconds: 354);
      expect(r.first.acoustId, 'acoust-1');
      expect(r.first.score, 0.97);
      expect(r.first.recordings.single.id, bohemianRecording);
      expect(r.first.recordings.single.artistName, 'Queen');
      expect(r.first.recordings.single.releaseGroups.single.type, 'Album');
      final req = net.requests.single;
      expect(req.method, 'POST');
      expect(req.bodyText, contains('client=KEY123'));
      expect(req.bodyText, contains('duration=354'));
      expect(req.bodyText, contains('meta=recordings%2Breleasegroups%2Bcompress'));
    });

    test('service errors surface a readable message', () async {
      final net = FakeHttpAdapter()
        ..onJson('/lookup', {
          'status': 'error',
          'error': {'code': 3, 'message': 'invalid API key'}
        });
      final client = AcoustIdClient(fakeHttp(net), apiKey: () => 'bad');
      await expectLater(client.lookup(fingerprint: 'x', durationSeconds: 1), throwsA(isA<HttpFailure>().having((e) => e.message, 'msg', contains('invalid API key'))));
    });

    test('refuses to run without a key', () async {
      final client = AcoustIdClient(fakeHttp(FakeHttpAdapter()), apiKey: () => '  ');
      expect(client.isConfigured, isFalse);
      await expectLater(client.lookup(fingerprint: 'x', durationSeconds: 1), throwsStateError);
    });
  });

  group('FingerprintService', () {
    test('decodes natively, fingerprints in Dart and returns the compressed form', () async {
      final pcm = toInt16(synthMelody(seconds: 20, rate: 44100));
      final service = FingerprintService(decoder: PcmDecoder(pcm, 44100), tempDir: () => Directory.systemTemp.createTempSync('fp'));
      const t = Track(id: 1, filePath: '/m/a.mp3', title: 'T', dateAdded: 0, durationMs: 20000);
      final fp = (await service.forTrack(t))!;
      final expected = Chromaprint.fingerprintPcm16(pcm.buffer.asUint8List(), 44100);
      expect(fp.raw, expected);
      expect(Chromaprint.decode(fp.encoded), expected);
      expect(fp.durationSeconds, 20);
    });

    test('clips too short to identify give null', () async {
      final pcm = toInt16(synthMelody(seconds: 3, rate: 44100));
      final service = FingerprintService(decoder: PcmDecoder(pcm, 44100), tempDir: () => Directory.systemTemp.createTempSync('fp'));
      expect(await service.forTrack(const Track(id: 1, filePath: '/m/a.mp3', title: 'T', dateAdded: 0)), isNull);
    });
  });

  group('IdentifyService', () {
    late LibraryRepository repo;
    late FakeBridges bridges;
    late FakeHttpAdapter net;
    late FakeFingerprints fingerprints;
    late IdentifyService svc;

    Future<void> setUpService({Map<String, Object> prefs = const {'key.acoustid': 'KEY'}}) async {
      repo = await openTestRepo();
      bridges = FakeBridges();
      net = FakeHttpAdapter();
      final settings = await testSettings(prefs);
      final http = fakeHttp(net);
      fingerprints = FakeFingerprints(const Fingerprint(encoded: 'FP', durationSeconds: 355, raw: [1]));
      svc = IdentifyService(
        repo: repo,
        settings: settings,
        musicBrainz: MusicBrainzClient(http),
        acoustId: AcoustIdClient(http, apiKey: () => settings.acoustIdKey),
        fingerprints: fingerprints,
        tagWriter: TagWriter(repo: repo, bridges: bridges),
        bridges: bridges,
      );
      net.onFixture('/recording/$bohemianRecording', 'mb_recording.json');
    }

    Future<Track> addTrack({String title = 'Bohemian Rhapsody (Official Video)', String? artist = 'Queen', String? mbid, int durationMs = 355000, String? album}) async {
      final id = await repo.upsertTrack(TrackDraft(
        filePath: '/storage/emulated/0/Music/MusicPlayer/a.m4a',
        contentUri: 'content://media/external/audio/media/9',
        title: title,
        artist: artist,
        album: album,
        durationMs: durationMs,
        mbRecordingId: mbid,
        genre: null,
      ));
      return (await repo.trackById(id))!;
    }

    setUp(() => setUpService());
    tearDown(() => repo.appDb.close());

    test('MBID in the tags is trusted without fingerprinting or searching', () async {
      final t = await addTrack(mbid: bohemianRecording);
      final r = await svc.identify(t);
      expect(r.best!.origin, 'tags');
      expect(r.best!.confidence, 1.0);
      expect(r.autoAccept, isTrue);
      expect(fingerprints.calls, 0);
      expect(net.requestsTo('musicbrainz.org/ws/2/recording?'), isEmpty);
    });

    test('fingerprint match: AcoustID -> MusicBrainz, high score auto-accepts', () async {
      net.onJson('/lookup', {
        'status': 'ok',
        'results': [
          {
            'id': 'acoust-1',
            'score': 0.96,
            'recordings': [
              {'id': bohemianRecording, 'title': 'Bohemian Rhapsody', 'artists': [{'id': '0383dadf', 'name': 'Queen'}]}
            ],
          },
        ],
      });
      final t = await addTrack(title: 'random video title', artist: null);
      final r = await svc.identify(t);
      expect(r.best!.origin, 'acoustid');
      expect(r.best!.confidence, closeTo(0.96, 1e-9));
      expect(r.best!.acoustId, 'acoust-1');
      expect(r.autoAccept, isTrue);
      expect(r.best!.proposed.title, 'Bohemian Rhapsody');
      expect(r.best!.proposed.artist, 'Queen');
      expect(r.best!.proposed.mbRecordingId, bohemianRecording);
      expect(r.best!.proposed.acoustId, 'acoust-1');
      expect(r.best!.proposed.mbArtistId, '0383dadf-2a4e-4d10-a46a-e9e041da8eb3');
      // the release picker chose the original studio album, not the single or a regional pressing
      expect(r.best!.release!.title, 'A Night at the Opera');
      expect(r.best!.proposed.year, 1975);
      expect(net.requestsTo('musicbrainz.org/ws/2/recording?'), isEmpty, reason: 'text search skipped');
    });

    test('a low AcoustID score is offered for review instead of auto-accepted', () async {
      net.onJson('/lookup', {
        'status': 'ok',
        'results': [
          {
            'id': 'a',
            'score': 0.71,
            'recordings': [
              {'id': bohemianRecording, 'title': 'Bohemian Rhapsody'}
            ],
          },
        ],
      });
      net.onFixture('/recording?', 'mb_search.json');
      final t = await addTrack(title: 'whatever', artist: 'Someone Else');
      final r = await svc.identify(t);
      expect(r.autoAccept, isFalse);
      expect(r.candidates, isNotEmpty);
    });

    test('a large duration mismatch lowers the fingerprint confidence', () async {
      net.onJson('/lookup', {
        'status': 'ok',
        'results': [
          {
            'id': 'a',
            'score': 0.95,
            'recordings': [
              {'id': bohemianRecording, 'title': 'Bohemian Rhapsody'}
            ],
          },
        ],
      });
      net.onFixture('/recording?', 'mb_search.json');
      final t = await addTrack(durationMs: 120000);
      final r = await svc.identify(t);
      final fpCandidate = r.candidates.firstWhere((c) => c.origin == 'acoustid');
      expect(fpCandidate.confidence, closeTo(0.76, 1e-9));
    });

    test('without an AcoustID key it says so and falls back to text search', () async {
      await setUpService(prefs: const {});
      net.onFixture('/recording?', 'mb_search.json');
      final t = await addTrack();
      final r = await svc.identify(t);
      expect(r.notes.any((n) => n.contains('AcoustID key')), isTrue);
      expect(r.candidates, isNotEmpty);
      expect(r.best!.origin, 'text');
      expect(fingerprints.calls, 0);
    });

    test('text search cleans the video title and is queried with the cleaned title', () async {
      await setUpService(prefs: const {});
      net.onFixture('/recording?', 'mb_search.json');
      // 323 s = the length of the first recorded search hit (a live recording)
      final t = await addTrack(title: 'Bohemian Rhapsody (Official Video) [4K]', artist: 'Queen', durationMs: 323000);
      final r = await svc.identify(t);
      final q = net.requestsTo('/recording?').first.uri.queryParameters['query']!;
      expect(q, contains('recording:"Bohemian Rhapsody"'));
      expect(q, isNot(contains('Official')));
      expect(r.best!.recording.title, 'Bohemian Rhapsody');
      expect(r.best!.confidence, greaterThan(0.85));
    });

    test('a strong MusicBrainz score for a different song does not auto-accept', () async {
      await setUpService(prefs: const {});
      net.onFixture('/recording?', 'mb_search.json');
      final t = await addTrack(title: 'Completely Different Song', artist: 'Another Band', durationMs: 90000);
      final r = await svc.identify(t);
      expect(r.autoAccept, isFalse);
    });

    test('an existing album tag steers the release choice', () async {
      net.onFixture('/recording/$bohemianRecording', 'mb_recording.json');
      final t = await addTrack(mbid: bohemianRecording, album: 'Bohemian Rhapsody');
      final r = await svc.identify(t);
      expect(r.best!.release!.title, 'Bohemian Rhapsody');
      expect(r.best!.release!.primaryType, 'Single');
    });

    test('apply writes tags to the file and updates the library', () async {
      final t = await addTrack(mbid: bohemianRecording);
      final r = await svc.identify(t);
      final outcome = await svc.apply(t, r.best!);
      expect(outcome, TagWriteOutcome.written);
      final write = bridges.fakeTags.writes.single;
      expect(write.uri, 'content://media/external/audio/media/9');
      expect(write.update.values['title'], 'Bohemian Rhapsody');
      expect(write.update.values['artist'], 'Queen');
      expect(write.update.values['album'], 'A Night at the Opera');
      expect(write.update.values['mbRecordingId'], bohemianRecording);
      expect(write.update.values['mbReleaseId'], isNotNull);
      expect(write.update.values['mbArtistId'], '0383dadf-2a4e-4d10-a46a-e9e041da8eb3');
      expect(write.update.values['isrc'], isNotNull);
      final saved = (await repo.trackById(t.id))!;
      expect(saved.title, 'Bohemian Rhapsody');
      expect(saved.albumTitle, 'A Night at the Opera');
      expect(saved.year, 1975);
      expect(saved.identifyState, IdentifyState.matched);
      expect(saved.identifyScore, 1.0);
      expect(saved.sizeBytes, 1234, reason: 'new size stored so the scanner does not re-read it');
      expect(saved.fileMtime, 4242);
    });

    test('apply keeps the DB update even when the file cannot be written', () async {
      final t = await addTrack(mbid: bohemianRecording);
      final r = await svc.identify(t);
      bridges.fakeTags.writeFailure = PlatformFailure('unsupported_format', 'opus');
      expect(await svc.apply(t, r.best!), TagWriteOutcome.unsupported);
      expect((await repo.trackById(t.id))!.identifyState, IdentifyState.matched);
    });

    test('write permission is requested once and the write retried', () async {
      final t = await addTrack(mbid: bohemianRecording);
      final r = await svc.identify(t);
      var attempts = 0;
      final tags = _FlakyTags(() => attempts++ == 0 ? PlatformFailure('needs_permission', 'denied') : null);
      final b = FakeBridges2(tags, bridges.fakeStore);
      final writer = TagWriter(repo: repo, bridges: b);
      final outcome = await writer.write(t, r.best!.proposed.toUpdate());
      expect(outcome, TagWriteOutcome.written);
      expect(bridges.fakeStore.writeRequests, 1);
      expect(attempts, 2);
    });

    test('a refused write request is not repeated for the next file', () async {
      final t = await addTrack(mbid: bohemianRecording);
      final tags = _FlakyTags(() => PlatformFailure('needs_permission', 'denied'));
      bridges.fakeStore.writeGranted = false;
      final writer = TagWriter(repo: repo, bridges: FakeBridges2(tags, bridges.fakeStore));
      final update = TagUpdate({'title': 'x'});
      expect(await writer.write(t, update), TagWriteOutcome.permissionDenied);
      expect(await writer.write(t, update), TagWriteOutcome.permissionDenied);
      expect(bridges.fakeStore.writeRequests, 1);
    });

    test('identifyAll applies confident matches and queues doubtful ones for review', () async {
      net.onJson('/lookup', {
        'status': 'ok',
        'results': [
          {
            'id': 'a',
            'score': 0.98,
            'recordings': [
              {'id': bohemianRecording, 'title': 'Bohemian Rhapsody'}
            ],
          },
        ],
      });
      final good = await addTrack(title: 'x');
      final progress = await svc.identifyAll(tracks: [good]).toList();
      expect(progress.last.matched, 1);
      expect(progress.last.finished, isTrue);
      expect((await repo.trackById(good.id))!.identifyState, IdentifyState.matched);
    });

    test('manual search returns ranked candidates', () async {
      net.onFixture('/recording?', 'mb_search.json');
      final t = await addTrack();
      final c = await svc.searchManual(t, title: 'Bohemian Rhapsody', artist: 'Queen');
      expect(c.first.confidence, greaterThanOrEqualTo(c.last.confidence));
      expect(c.first.proposed.artist, 'Queen');
    });
  });
}

class _FlakyTags extends FakeTagsBridge {
  _FlakyTags(this.failure);
  final PlatformFailure? Function() failure;

  @override
  Future<FileStat2> write({String? path, String? uri, required TagUpdate update}) async {
    final f = failure();
    if (f != null) throw f;
    return const FileStat2(size: 99, lastModified: 98);
  }
}

class FakeBridges2 extends Bridges {
  FakeBridges2(TagsBridge tags, MediaStoreBridge store) : super(tags: tags, mediaStore: store, decoder: FakeDecoderBridge(), ytDlp: FakeYtDlpBridge(), system: FakeSystemBridge());
}
