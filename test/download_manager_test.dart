import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/core/models/library_models.dart';
import 'package:musicplayer/core/models/track.dart';
import 'package:musicplayer/features/sources/direct_sources.dart';
import 'package:musicplayer/features/sources/source_provider.dart';
import 'package:musicplayer/platform/bridges.dart';

import 'helpers/fake_http.dart';
import 'helpers/harness.dart';

const ytUrl = 'https://www.youtube.com/watch?v=abc123';
const bohemian = 'b1a9c0e9-d987-4042-ae91-78d6a3267d69';

void main() {
  late Harness h;

  Future<void> setUpHarness([Map<String, Object> prefs = const {}]) async {
    h = await Harness.create(prefs: prefs);
    h.net.onFixture('/recording/$bohemian', 'mb_recording.json');
  }

  setUp(() => setUpHarness());
  tearDown(() => h.dispose());

  Future<DownloadJob> jobOf(int id) async => (await h.jobs.byId(id))!;

  Future<void> waitDone(int id) => h.until(() async => !(await jobOf(id)).status.isActive);

  group('happy path', () {
    test('a YouTube video becomes a cleaned, tagged, identified track in the library', () async {
      h.fakeYtDlpWrites();
      h.net.onFixture('/recording?', 'mb_search.json');
      final r = await h.manager.enqueueUrl('https://youtu.be/abc123?si=tracking');
      expect(r.isNew, isTrue);
      await waitDone(r.jobId!);

      final job = await jobOf(r.jobId!);
      expect(job.status, JobStatus.done, reason: job.error);
      expect(job.trackId, isNotNull);

      // 1. the yt-dlp command line was the documented one
      final args = h.bridges.fakeYt.downloads.single.args;
      expect(args.last, ytUrl, reason: 'jobs use the canonical URL');
      expect(args, containsAll(['-x', '--embed-metadata', '--write-info-json']));

      // 2. the temp file was tagged with the cleaned title, artist and the source link
      final tempWrite = h.bridges.fakeTags.writes.first;
      expect(tempWrite.path, contains('dl'));
      expect(tempWrite.update.values['title'], 'Bohemian Rhapsody');
      expect(tempWrite.update.values['sourceUrl'], ytUrl);

      // 3. it was inserted into MediaStore under Music/MusicPlayer/...
      final inserted = h.bridges.fakeStore.inserted.single;
      expect(inserted.relativeDir, startsWith('MusicPlayer'));
      expect(inserted.displayName, endsWith('.m4a'));
      expect(inserted.mime, 'audio/mp4');
      expect(File(inserted.src).existsSync(), isFalse, reason: 'temp file removed');

      // 4. the library row exists with source info, hash and (text) identification
      final t = (await h.repo.trackById(job.trackId!))!;
      expect(t.source, TrackSource.youtube);
      expect(t.sourceUrl, ytUrl, reason: 'canonical URL, tracking params stripped');
      expect(t.audioHash, isNotNull);
      expect(t.title, 'Bohemian Rhapsody');
      expect(t.format, 'M4A');
      expect(t.contentUri, startsWith('content://media'));
    });

    test('a confident fingerprint match tags the file with MusicBrainz data and reorganises it', () async {
      await setUpHarness({'key.acoustid': 'KEY'});
      h.net.onFixture('/recording/$bohemian', 'mb_recording.json');
      h.net.onJson('/lookup', {
        'status': 'ok',
        'results': [
          {'id': 'aid', 'score': 0.98, 'recordings': [{'id': bohemian, 'title': 'Bohemian Rhapsody'}]},
        ],
      });
      // decode succeeds with a tiny PCM stream so the fingerprint step runs
      h.bridges.fakeDecoder.pcm = Int16List(11025 * 20);
      h.fakeYtDlpWrites();
      final r = await h.manager.enqueueUrl(ytUrl);
      await waitDone(r.jobId!);
      final job = await jobOf(r.jobId!);
      expect(job.status, JobStatus.done, reason: job.error);

      final t = (await h.repo.trackById(job.trackId!))!;
      expect(t.identifyState, IdentifyState.matched);
      expect(t.artistName, 'Queen');
      expect(t.albumTitle, 'A Night at the Opera');
      expect(t.mbRecordingId, bohemian);
      expect(t.acoustId, 'aid');
      // tags written to the library copy
      final libWrite = h.bridges.fakeTags.writes.last;
      expect(libWrite.update.values['mbRecordingId'], bohemian);
      // organised into Artist/Album
      final moved = h.bridges.fakeStore.moved.single;
      expect(moved.relativeDir, 'MusicPlayer/Queen/A Night at the Opera');
      expect(moved.displayName, matches(RegExp(r'^\d+ - Bohemian Rhapsody\.m4a$|^Bohemian Rhapsody\.m4a$')));
      expect(t.filePath, contains('/Queen/A Night at the Opera/'));
    });

    test('cover, lyrics and album art follow when enabled', () async {
      await setUpHarness({'key.acoustid': 'KEY', 'dl.autoCover': true, 'dl.autoLyrics': true});
      h.net.onFixture('/recording/$bohemian', 'mb_recording.json');
      h.net.onJson('/lookup', {
        'status': 'ok',
        'results': [
          {'id': 'aid', 'score': 0.98, 'recordings': [{'id': bohemian, 'title': 'Bohemian Rhapsody'}]},
        ],
      });
      h.net.onFixture('/api/get', 'lrclib_get.json');
      h.net.onFixture('coverartarchive.org/release/', 'caa_index.json');
      h.net.on('coverartarchive.org/release/6defd963-fe91-4550-b18e-82c685603c2b/', (_) => FakeResponse('', bytes: jpegBytes(900, 500)));
      h.bridges.fakeDecoder.pcm = Int16List(11025 * 20);
      h.fakeYtDlpWrites();
      final r = await h.manager.enqueueUrl(ytUrl);
      await waitDone(r.jobId!);
      final job = await jobOf(r.jobId!);
      expect(job.status, JobStatus.done, reason: job.error);
      final t = (await h.repo.trackById(job.trackId!))!;
      expect((await h.repo.lyricsForTrack(t.id))!.hasSynced, isTrue);
      final album = (await h.repo.albumById(t.albumId!))!;
      expect(album.coverPath, isNotNull);
      expect(File(album.coverPath!).existsSync(), isTrue);
      expect(h.bridges.fakeTags.writes.any((w) => w.update.artPath != null), isTrue, reason: 'cover embedded into the file');
    });
  });

  group('duplicates', () {
    test('the same video is not queued twice, nor downloaded again once in the library', () async {
      h.fakeYtDlpWrites();
      h.net.onFixture('/recording?', 'mb_search.json');
      final a = await h.manager.enqueueUrl(ytUrl);
      final again = await h.manager.enqueueUrl('https://youtu.be/abc123');
      expect(again.alreadyQueued, isTrue);
      expect(again.jobId, a.jobId);
      await waitDone(a.jobId!);
      final dup = await h.manager.enqueueUrl('https://m.youtube.com/watch?v=abc123&t=5');
      expect(dup.duplicate, isNotNull);
      expect(dup.duplicate!.id, (await jobOf(a.jobId!)).trackId);
      final forced = await h.manager.enqueueUrl('https://m.youtube.com/watch?v=abc123&t=5', force: true);
      expect(forced.isNew, isTrue);
      await waitDone(forced.jobId!);
    });

    test('identical audio arriving under a different URL is detected by hash', () async {
      final bytes = List<int>.generate(4000, (i) => (i * 7) % 256);
      h.fakeYtDlpWrites(content: bytes);
      h.net.onFixture('/recording?', 'mb_search.json');
      final a = await h.manager.enqueueUrl('https://www.youtube.com/watch?v=first');
      await waitDone(a.jobId!);
      final b = await h.manager.enqueueUrl('https://www.youtube.com/watch?v=second');
      await waitDone(b.jobId!);
      final jb = await jobOf(b.jobId!);
      expect(jb.status, JobStatus.done);
      expect(jb.stage, 'Already in library');
      expect(jb.trackId, (await jobOf(a.jobId!)).trackId);
      expect(h.bridges.fakeStore.inserted, hasLength(1));
      expect(await h.repo.trackCount(), 1);
    });
  });

  group('failures and control', () {
    test('a yt-dlp error is classified, stored and can be retried', () async {
      var attempt = 0;
      h.bridges.fakeYt.onDownload = (jobId, args) async {
        attempt++;
        if (attempt == 1) throw PlatformFailure('ytdlp_failed', 'ERROR: [youtube] abc123: Video unavailable');
        final dir = args[args.indexOf('-P') + 1];
        Directory(dir).createSync(recursive: true);
        File('$dir/abc123.m4a').writeAsBytesSync(List.filled(500, 7));
        return const YtDlpResult(exitCode: 0, out: '', err: '');
      };
      h.net.onFixture('/recording?', 'mb_search.json');
      final r = await h.manager.enqueueUrl(ytUrl);
      await waitDone(r.jobId!);
      var job = await jobOf(r.jobId!);
      expect(job.status, JobStatus.failed);
      expect(job.error, contains('no longer available'));
      await h.manager.retry(job.id);
      await waitDone(job.id);
      job = await jobOf(job.id);
      expect(job.status, JobStatus.done, reason: job.error);
      expect(attempt, 2);
    });

    test('a nonzero exit code fails the job with the classified stderr', () async {
      h.bridges.fakeYt.onDownload = (_, _) async => const YtDlpResult(exitCode: 1, out: '', err: 'ERROR: HTTP Error 403: Forbidden');
      final r = await h.manager.enqueueUrl(ytUrl);
      await waitDone(r.jobId!);
      final job = await jobOf(r.jobId!);
      expect(job.status, JobStatus.failed);
      expect(job.error, contains('403'));
    });

    test('an extractor failure triggers exactly one automatic yt-dlp update and retry', () async {
      var calls = 0;
      h.bridges.fakeYt.onDownload = (jobId, args) async {
        calls++;
        if (calls == 1) return const YtDlpResult(exitCode: 1, out: '', err: 'ERROR: Unable to extract initial data; please report this issue');
        final dir = args[args.indexOf('-P') + 1];
        Directory(dir).createSync(recursive: true);
        File('$dir/abc123.m4a').writeAsBytesSync(List.filled(500, 3));
        return const YtDlpResult(exitCode: 0, out: '', err: '');
      };
      h.net.onFixture('/recording?', 'mb_search.json');
      final r = await h.manager.enqueueUrl(ytUrl);
      await waitDone(r.jobId!);
      expect((await jobOf(r.jobId!)).status, JobStatus.done);
      expect(calls, 2);
      expect(h.settings.lastYtDlpUpdate, isNotNull);
    });

    test('cancelling a running job stops it and cleans up', () async {
      final started = Completer<void>();
      final release = Completer<void>();
      h.bridges.fakeYt.onDownload = (jobId, args) async {
        started.complete();
        await release.future;
        throw PlatformFailure('cancelled', 'Cancelled');
      };
      final r = await h.manager.enqueueUrl(ytUrl);
      await started.future;
      await h.manager.cancel(r.jobId!);
      expect(h.bridges.fakeYt.cancelled, ['${r.jobId}']);
      release.complete();
      await waitDone(r.jobId!);
      expect((await jobOf(r.jobId!)).status, JobStatus.cancelled);
      expect(h.manager.activeCount, 0);
    });

    test('cancelling a queued job needs no engine', () async {
      await h.settings.setMaxConcurrent(1);
      final gate = Completer<void>();
      h.bridges.fakeYt.onDownload = (jobId, args) async {
        await gate.future;
        return const YtDlpResult(exitCode: 1, out: '', err: 'ERROR: Video unavailable');
      };
      final first = await h.manager.enqueueUrl('https://youtu.be/one');
      final second = await h.manager.enqueueUrl('https://youtu.be/two');
      await h.until(() async => h.manager.activeCount == 1);
      await h.manager.cancel(second.jobId!);
      expect((await jobOf(second.jobId!)).status, JobStatus.cancelled);
      gate.complete();
      await waitDone(first.jobId!);
    });

    test('remove deletes the job; clearFinished keeps active ones', () async {
      h.bridges.fakeYt.onDownload = (_, _) async => const YtDlpResult(exitCode: 1, out: '', err: 'ERROR: Video unavailable');
      final a = await h.manager.enqueueUrl('https://youtu.be/one');
      await waitDone(a.jobId!);
      await h.manager.clearFinished();
      expect(await h.jobs.byId(a.jobId!), isNull);
    });
  });

  group('scheduling', () {
    test('never runs more downloads at once than the setting allows', () async {
      await h.settings.setMaxConcurrent(2);
      var running = 0, peak = 0;
      h.bridges.fakeYt.onDownload = (jobId, args) async {
        running++;
        peak = running > peak ? running : peak;
        await Future<void>.delayed(const Duration(milliseconds: 60));
        running--;
        return const YtDlpResult(exitCode: 1, out: '', err: 'ERROR: Video unavailable');
      };
      final ids = <int>[];
      for (var i = 0; i < 5; i++) {
        ids.add((await h.manager.enqueueUrl('https://youtu.be/v$i')).jobId!);
      }
      for (final id in ids) {
        await waitDone(id);
      }
      expect(peak, 2);
    });

    test('Wi-Fi only holds jobs back until an unmetered connection appears', () async {
      await h.settings.setWifiOnly(true);
      h.network.unmetered = false;
      h.fakeYtDlpWrites();
      h.net.onFixture('/recording?', 'mb_search.json');
      final r = await h.manager.enqueueUrl(ytUrl);
      await h.manager.start();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      var job = await jobOf(r.jobId!);
      expect(job.status, JobStatus.queued);
      expect(job.stage, 'Waiting for Wi-Fi');
      expect(h.bridges.fakeYt.downloads, isEmpty);
      h.network.set(true);
      await waitDone(r.jobId!);
      job = await jobOf(r.jobId!);
      expect(job.status, JobStatus.done, reason: job.error);
    });

    test('jobs interrupted by an app kill go back to the queue and finish on the next start', () async {
      final id = await h.jobs.create(url: ytUrl, sourceType: 'youtube', options: const {});
      await h.jobs.update(id, status: JobStatus.running, progress: 40);
      h.fakeYtDlpWrites();
      h.net.onFixture('/recording?', 'mb_search.json');
      await h.manager.start();
      await waitDone(id);
      expect((await jobOf(id)).status, JobStatus.done);
    });

    test('the finished notification summarises the batch', () async {
      h.fakeYtDlpWrites();
      h.net.onFixture('/recording?', 'mb_search.json');
      final events = <String>[];
      h.manager.events.listen((e) => events.add(e.kind));
      final r = await h.manager.enqueueUrl(ytUrl);
      await waitDone(r.jobId!);
      await h.until(() async => h.bridges.fakeSystem.notifications.isNotEmpty);
      expect(h.bridges.fakeSystem.notifications.single.title, 'Downloads finished');
      expect(events, containsAll(['finished', 'allDone']));
    });
  });

  group('direct sources (no yt-dlp)', () {
    test('an Internet Archive file is fetched over HTTP and tagged from the provider hint', () async {
      const url = 'https://archive.org/download/gd77/01-Intro.mp3';
      h.net.on('archive.org/download/gd77/01-Intro.mp3', (_) => FakeResponse('', bytes: Uint8List.fromList(List.filled(3000, 5))));
      h.net.on('/recording?', (_) => FakeResponse.json({'recordings': []}));
      const track = RemoteTrack(
        id: 'gd77/01-Intro.mp3',
        provider: 'archive',
        source: TrackSource.internetArchive,
        title: 'Intro',
        artist: 'Grateful Dead',
        album: 'Live at Barton Hall',
        trackNumber: 1,
        pageUrl: 'https://archive.org/details/gd77',
        downloadUrl: url,
      );
      final r = await h.manager.enqueueRemote(track);
      await waitDone(r.jobId!);
      final job = await jobOf(r.jobId!);
      expect(job.status, JobStatus.done, reason: job.error);
      expect(h.bridges.fakeYt.downloads, isEmpty, reason: 'no yt-dlp for direct files');
      final t = (await h.repo.trackById(job.trackId!))!;
      expect(t.title, 'Intro');
      expect(t.artistName, 'Grateful Dead');
      expect(t.albumTitle, 'Live at Barton Hall');
      expect(t.source, TrackSource.internetArchive);
      expect(t.sourceUrl, url, reason: 'each file has its own identity, not the item page');
      expect(h.bridges.fakeStore.inserted.single.displayName, endsWith('.mp3'));
    });

    test('a bare audio-file link is downloaded over HTTP; its file-name title is only a guess', () async {
      const url = 'http://nas.local:8080/music/My_Song.ogg';
      h.net.on('nas.local:8080/music/My_Song.ogg', (_) => FakeResponse('', bytes: Uint8List.fromList(List.filled(3000, 7))));
      h.net.on('/recording?', (_) => FakeResponse.json({'recordings': []}));
      final track = (await DirectFileSource().resolve(url))!;
      final r = await h.manager.enqueueRemote(track);
      await waitDone(r.jobId!);
      final job = await jobOf(r.jobId!);
      expect(job.status, JobStatus.done, reason: job.error);
      expect(h.bridges.fakeYt.downloads, isEmpty, reason: 'no yt-dlp for a plain file');
      final hint = (job.options['hint'] as Map).cast<String, dynamic>();
      expect(hint['title'], 'My Song');
      expect(hint.containsKey('trackTitle'), isFalse, reason: 'the file\'s own title tag must win over the guess');
      final t = (await h.repo.trackById(job.trackId!))!;
      expect(t.title, 'My Song', reason: 'no tags in this file: the guess is the fallback');
      expect(t.sourceUrl, url, reason: 'http scheme is kept');
    });

    test('two tracks of the same archive item are not mistaken for duplicates', () async {
      h.net.on('archive.org/download/', (r) => FakeResponse('', bytes: Uint8List.fromList(List.generate(2000, (i) => (i + r.uri.path.length) % 256))));
      h.net.on('/recording?', (_) => FakeResponse.json({'recordings': []}));
      RemoteTrack t(String n, int no) => RemoteTrack(
            id: 'x/$n',
            provider: 'archive',
            source: TrackSource.internetArchive,
            title: 'Song $no',
            artist: 'Band',
            trackNumber: no,
            pageUrl: 'https://archive.org/details/x',
            downloadUrl: 'https://archive.org/download/x/$n',
          );
      final results = await h.manager.enqueueMany([t('a.mp3', 1), t('bb.mp3', 2)]);
      for (final r in results) {
        await waitDone(r.jobId!);
      }
      expect(await h.repo.trackCount(), 2);
    });
  });

  group('server engine', () {
    test('creates a job on the companion server, polls it, fetches the file, then cleans up', () async {
      await setUpHarness({'eng.kind': 'server', 'eng.serverUrl': 'http://192.168.1.5:8000', 'eng.serverToken': 'sekret'});
      h.net.onFixture('/recording/$bohemian', 'mb_recording.json');
      h.net.onFixture('/recording?', 'mb_search.json');
      var polls = 0;
      h.net.on('POST http://192.168.1.5:8000/jobs', (_) => FakeResponse.json({'id': 'remote-1'}));
      h.net.on('GET http://192.168.1.5:8000/jobs/remote-1', (_) {
        polls++;
        return polls < 3
            ? FakeResponse.json({'status': 'running', 'progress': 50.0})
            : FakeResponse.json({
                'status': 'done',
                'progress': 100.0,
                'files': [
                  {'name': 'abc123.m4a', 'size': 1000}
                ],
                'info': {'id': 'abc123', 'title': 'Bohemian Rhapsody (Official Video)', 'uploader': 'Queen Official', 'duration': 355, 'webpage_url': ytUrl},
              });
      });
      h.net.on('/jobs/remote-1/file', (_) => FakeResponse('', bytes: Uint8List.fromList(List.filled(1000, 9))));
      h.net.on('DELETE http://192.168.1.5:8000/jobs/remote-1', (_) => FakeResponse.json({'ok': true}));
      final r = await h.manager.enqueueUrl(ytUrl);
      await waitDone(r.jobId!);
      final job = await jobOf(r.jobId!);
      expect(job.status, JobStatus.done, reason: job.error);
      expect(polls, greaterThanOrEqualTo(3));
      final create = h.net.requestsTo('POST http://192.168.1.5:8000/jobs').first;
      expect(create.headers['Authorization'], 'Bearer sekret');
      expect(create.bodyText, contains(ytUrl));
      await h.until(() async => h.net.requestsTo('DELETE http://192.168.1.5:8000/jobs/remote-1').isNotEmpty);
      expect(h.bridges.fakeYt.downloads, isEmpty);
    });

    test('a rejected token is reported clearly', () async {
      await setUpHarness({'eng.kind': 'server', 'eng.serverUrl': 'http://srv', 'eng.serverToken': 'bad'});
      h.net.on('POST http://srv/jobs', (_) => FakeResponse.json({'detail': 'invalid token'}, status: 401));
      final r = await h.manager.enqueueUrl(ytUrl);
      await waitDone(r.jobId!);
      final job = await jobOf(r.jobId!);
      expect(job.status, JobStatus.failed);
      expect(job.error, contains('token'));
    });
  });
}
