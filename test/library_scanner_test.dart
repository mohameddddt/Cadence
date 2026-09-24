import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/core/library/library_repository.dart';
import 'package:musicplayer/core/models/track.dart';
import 'package:musicplayer/features/library/library_scanner.dart';
import 'package:musicplayer/platform/bridges.dart';

import 'helpers/fakes.dart';
import 'helpers/test_db.dart';

AudioFileInfo file(
  String path, {
  int mtime = 100,
  int size = 1000,
  int durationMs = 200000,
  String? title,
  String? artist,
  String? album,
  String? relativePath,
}) =>
    AudioFileInfo(
      uri: 'content://media/external/audio/media/${path.hashCode.abs()}',
      path: path,
      displayName: path.split('/').last,
      title: title,
      artist: artist,
      album: album,
      durationMs: durationMs,
      size: size,
      dateModified: mtime,
      relativePath: relativePath,
    );

void main() {
  late LibraryRepository repo;
  late FakeBridges bridges;
  late LibraryScanner scanner;
  final existing = <String>{};

  Future<void> setUpScanner([Map<String, Object> prefs = const {}]) async {
    repo = await openTestRepo();
    bridges = FakeBridges();
    existing.clear();
    scanner = LibraryScanner(
      repo: repo,
      bridges: bridges,
      settings: await testSettings(prefs),
      readConcurrency: 2,
      batchSize: 3,
      fileExists: existing.contains,
    );
  }

  setUp(() => setUpScanner());
  tearDown(() async {
    await scanner.dispose();
    await repo.appDb.close();
  });

  test('first scan adds every file with tags merged over MediaStore data', () async {
    bridges.fakeStore.audio = [file('/m/a/1.mp3', title: 'ms title', artist: 'ms artist', album: 'a')];
    bridges.fakeTags.byKey['/m/a/1.mp3'] = const TagData(
      title: 'Real Title',
      artist: 'Real Artist',
      album: 'Real Album',
      albumArtist: 'Real Artist',
      date: '1999-03-01',
      trackNo: 4,
      discNo: 1,
      genre: 'Rock',
      durationMs: 201000,
      replayGainTrack: '-6.50 dB',
      mbRecordingId: 'rec-1',
      hasArt: true,
    );
    final r = await scanner.scan();
    expect(r.added, 1);
    final t = (await repo.tracksByIds([1])).single;
    expect(t.title, 'Real Title');
    expect(t.artistName, 'Real Artist');
    expect(t.albumTitle, 'Real Album');
    expect(t.year, 1999);
    expect(t.trackNo, 4);
    expect(t.durationMs, 201000);
    expect(t.replayGainTrack, -6.5);
    expect(t.hasEmbeddedArt, isTrue);
    expect(t.identifyState, IdentifyState.matched);
    expect(t.format, 'MP3');
    expect(t.folder, '/m/a');
  });

  test('untagged files get a title from the file name and no bogus MediaStore album', () async {
    bridges.fakeStore.audio = [file('/m/Download/My Song.mp3', album: 'Download')];
    await scanner.scan();
    final t = (await repo.tracks()).single;
    expect(t.title, 'My Song');
    expect(t.albumTitle, isNull);
  });

  test('second scan skips unchanged files and only re-reads changed ones', () async {
    bridges.fakeStore.audio = [file('/m/1.mp3'), file('/m/2.mp3'), file('/m/3.mp3')];
    await scanner.scan();
    expect(bridges.fakeTags.reads, 3);

    bridges.fakeStore.audio = [file('/m/1.mp3'), file('/m/2.mp3', mtime: 999), file('/m/3.mp3')];
    final r = await scanner.scan();
    expect(bridges.fakeTags.reads, 4, reason: 'only the changed file is read again');
    expect(r.updated, 1);
    expect(r.skipped, 2);
    expect(r.added, 0);
  });

  test('deleted files are removed, unless they still exist on disk', () async {
    bridges.fakeStore.audio = [file('/m/keep.mp3'), file('/m/gone.mp3'), file('/m/hidden.mp3')];
    await scanner.scan();
    bridges.fakeStore.audio = [file('/m/keep.mp3')];
    existing.add('/m/hidden.mp3');
    final r = await scanner.scan();
    expect(r.removed, 1);
    expect((await repo.tracks()).map((t) => t.title).toSet(), {'keep', 'hidden'});
  });

  test('a short track the user downloaded survives the short-clip filter that removes ringtones', () async {
    await repo.upsertTrack(TrackDraft(filePath: '/m/dl/jingle.ogg', title: 'Jingle', durationMs: 20000, source: TrackSource.soundcloud));
    bridges.fakeStore.audio = [
      file('/m/dl/jingle.ogg', durationMs: 20000),
      file('/m/ring.mp3', durationMs: 20000),
    ];
    final r = await scanner.scan();
    expect(r.removed, 0);
    expect((await repo.tracks()).map((t) => t.filePath).toSet(), {'/m/dl/jingle.ogg'}, reason: 'the unknown 20 s file is still a ringtone');
    // ... and again once the file was re-read with a new mtime.
    bridges.fakeStore.audio = [file('/m/dl/jingle.ogg', durationMs: 20000, mtime: 999)];
    await scanner.scan();
    expect((await repo.tracks()).map((t) => t.filePath).toSet(), {'/m/dl/jingle.ogg'});
  });

  test('a track added while the scan is listing (a finishing download) is not removed', () async {
    bridges.fakeStore.audio = [file('/m/old.mp3')];
    await scanner.scan();
    bridges.fakeStore.duringQuery = () async {
      // Same order of events as the download pipeline: the row exists, the listing predates it.
      await repo.upsertTrack(TrackDraft(filePath: '/m/dl/new.ogg', title: 'New', durationMs: 20000, source: TrackSource.other));
    };
    final r = await scanner.scan();
    expect(r.removed, 0);
    expect((await repo.tracks()).map((t) => t.title).toSet(), {'old', 'New'});
  });

  test('an empty MediaStore answer because permission failed never wipes the library', () async {
    bridges.fakeStore.audio = [file('/m/1.mp3'), file('/m/2.mp3')];
    await scanner.scan();
    bridges.fakeStore.failQuery = true;
    final r = await scanner.scan();
    expect(r.removed, 0);
    expect(await repo.trackCount(), 2);
  });

  test('an empty (not failed) answer while tracks exist removes them - the files are gone', () async {
    bridges.fakeStore.audio = [file('/m/1.mp3')];
    await scanner.scan();
    bridges.fakeStore.audio = [file('/m/other.mp3')];
    final r = await scanner.scan();
    expect(r.removed, 1);
    expect(r.added, 1);
  });

  test('short clips are skipped (ringtones, voice notes)', () async {
    bridges.fakeStore.audio = [file('/m/song.mp3'), file('/m/beep.mp3', durationMs: 3000)];
    await scanner.scan();
    expect((await repo.tracks()).map((t) => t.title), ['song']);
  });

  test('duration filter applies to SAF files once their tags are read', () async {
    bridges.fakeStore.folders = [const PickedFolder(uri: 'content://tree/1', name: 'SD')];
    bridges.fakeStore.trees['content://tree/1'] = [
      const AudioFileInfo(uri: 'content://doc/1', displayName: 'long.flac', size: 10, dateModified: 5),
      const AudioFileInfo(uri: 'content://doc/2', displayName: 'short.flac', size: 10, dateModified: 5),
    ];
    bridges.fakeTags.byKey['content://doc/1'] = const TagData(title: 'Long', durationMs: 240000);
    bridges.fakeTags.byKey['content://doc/2'] = const TagData(title: 'Short', durationMs: 4000);
    await scanner.scan();
    final t = await repo.tracks();
    expect(t.map((e) => e.title), ['Long']);
    expect(t.single.filePath, 'content://doc/1', reason: 'no real path: the URI is the key');
    expect(t.single.hasRealPath, isFalse);
  });

  test('a file seen by both MediaStore and a picked folder is stored once', () async {
    bridges.fakeStore.audio = [file('/storage/emulated/0/Music/a.mp3')];
    bridges.fakeStore.folders = [const PickedFolder(uri: 'content://tree/1', name: 'Music')];
    bridges.fakeStore.trees['content://tree/1'] = [
      const AudioFileInfo(uri: 'content://doc/a', path: '/storage/emulated/0/Music/a.mp3', displayName: 'a.mp3', size: 1000, dateModified: 100),
    ];
    await scanner.scan();
    expect(await repo.trackCount(), 1);
  });

  test('excluded folders and messaging audio are ignored, and removed if already known', () async {
    await setUpScanner({'lib.excluded': ['/m/podcasts']});
    bridges.fakeStore.audio = [
      file('/m/music/a.mp3'),
      file('/m/podcasts/ep1.mp3'),
      file('/m/WhatsApp/Media/WhatsApp Audio/note.mp3'),
    ];
    await scanner.scan();
    expect((await repo.tracks()).map((t) => t.title), ['a']);

    // A folder excluded later removes what was scanned before.
    await scanner.dispose();
    repo = await openTestRepo();
    scanner = LibraryScanner(repo: repo, bridges: bridges, settings: await testSettings(), fileExists: (_) => false);
    await scanner.scan();
    expect(await repo.trackCount(), 2, reason: 'WhatsApp still filtered, podcasts now allowed');
    final settings = await testSettings({'lib.excluded': ['/m/podcasts']});
    final s2 = LibraryScanner(repo: repo, bridges: bridges, settings: settings, fileExists: (_) => true);
    final r = await s2.scan();
    expect(r.removed, 1);
    await s2.dispose();
  });

  test('unreadable tags fall back to MediaStore data instead of dropping the file', () async {
    bridges.fakeStore.audio = [file('/m/weird.opus', title: 'From MediaStore', artist: 'Someone')];
    bridges.fakeTags.failing.add('/m/weird.opus');
    final r = await scanner.scan();
    expect(r.failed, 1);
    final t = (await repo.tracks()).single;
    expect(t.title, 'From MediaStore');
    expect(t.artistName, 'Someone');
  });

  test('concurrent scan() calls share one run', () async {
    bridges.fakeStore.audio = [file('/m/1.mp3')];
    final a = scanner.scan();
    final b = scanner.scan();
    expect(identical(a, b), isTrue);
    await a;
    expect(scanner.isScanning, isFalse);
  });

  test('a downloaded file that carries its source URL is recognised as such', () async {
    bridges.fakeStore.audio = [file('/m/dl.m4a')];
    bridges.fakeTags.byKey['/m/dl.m4a'] = const TagData(title: 'T', sourceUrl: 'https://www.youtube.com/watch?v=abc');
    await scanner.scan();
    final t = (await repo.tracks()).single;
    expect(t.source, TrackSource.youtube);
    expect(t.sourceUrl, 'https://www.youtube.com/watch?v=abc');
  });

  test('MediaStore change events trigger a debounced rescan', () async {
    bridges.fakeStore.audio = [file('/m/1.mp3')];
    scanner.startWatching(debounce: const Duration(milliseconds: 30));
    bridges.fakeStore.fireChange();
    bridges.fakeStore.fireChange();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(await repo.trackCount(), 1);
  });

  test('progress is reported while reading', () async {
    bridges.fakeStore.audio = [for (var i = 0; i < 7; i++) file('/m/$i.mp3')];
    final seen = <String>[];
    final sub = scanner.progress.listen((p) => seen.add('${p.phase}:${p.done}/${p.total}'));
    await scanner.scan();
    await Future<void>.delayed(Duration.zero); // broadcast events are delivered asynchronously
    await sub.cancel();
    expect(seen.first, 'listing:0/0');
    expect(seen, contains('reading:7/7'));
    expect(seen.last, 'done:7/7');
  });
}
