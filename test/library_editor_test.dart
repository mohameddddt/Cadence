import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/core/library/library_repository.dart';
import 'package:musicplayer/core/models/library_models.dart';
import 'package:musicplayer/features/library/library_editor.dart';
import 'package:musicplayer/features/metadata/tag_writer.dart';
import 'package:musicplayer/platform/bridges.dart';

import 'helpers/fakes.dart';
import 'helpers/test_db.dart';
import 'library_repository_test.dart' show draft;

/// Files that need Android's write-access dialog until the store's requestWrite is granted.
class _LockedTags extends FakeTagsBridge {
  bool locked = false;
  final Set<String> unlocked = {};

  @override
  Future<FileStat2> write({String? path, String? uri, required TagUpdate update}) {
    if (locked && !unlocked.contains(uri)) throw PlatformFailure('needs_permission', 'denied');
    return super.write(path: path, uri: uri, update: update);
  }
}

class _Store extends FakeMediaStoreBridge {
  _Store(this.tags);
  final _LockedTags tags;

  @override
  Future<bool> requestWrite(List<String> uris) async {
    final ok = await super.requestWrite(uris);
    if (ok) tags.unlocked.addAll(uris);
    return ok;
  }
}

class _Bridges extends Bridges {
  _Bridges(TagsBridge tags, MediaStoreBridge store) : super(tags: tags, mediaStore: store, decoder: FakeDecoderBridge(), ytDlp: FakeYtDlpBridge(), system: FakeSystemBridge());
}

void main() {
  late LibraryRepository repo;
  late _LockedTags tags;
  late _Store store;
  late LibraryEditor editor;

  Future<LibraryEditor> makeEditor({bool writeTags = true}) async {
    tags = _LockedTags();
    store = _Store(tags);
    final settings = await testSettings({'meta.writeTags': writeTags});
    return LibraryEditor(
      repo: repo,
      tagWriter: TagWriter(repo: repo, bridges: _Bridges(tags, store)),
      settings: settings,
      imagesDir: () => Directory.systemTemp,
    );
  }

  Future<void> addTrack(String n, {String artist = 'Band', String album = 'Album', String? albumArtist, int? year}) {
    final d = draft('/m/a/$n.mp3', 'Song $n', artist: artist, album: album, albumArtist: albumArtist, no: int.parse(n), year: year);
    d.contentUri = 'content://media/external/audio/media/$n';
    return repo.upsertTrack(d);
  }

  Future<Album> firstAlbum() async => (await repo.albums()).first;

  setUp(() async {
    repo = await openTestRepo();
    editor = await makeEditor();
  });

  tearDown(() async => repo.appDb.close());

  test('album edit writes only the changed fields into every file, then updates the library', () async {
    for (final n in ['1', '2', '3']) {
      await addTrack(n, albumArtist: 'Band', year: 2001);
    }
    final album = await firstAlbum();

    final report = await editor.editAlbum(album, title: 'Renamed', albumArtist: 'Band', year: 2001);

    expect(tags.writes.length, 3);
    for (final w in tags.writes) {
      expect(w.update.values, {'album': 'Renamed'}, reason: 'unchanged artist and year must not be rewritten');
    }
    expect(report.written, 3);
    expect(report.describe('Album'), 'Album saved in all 3 files');
    expect((await repo.albumById(album.id))!.title, 'Renamed');
  });

  test('an edit that changes nothing touches neither files nor rows', () async {
    await addTrack('1', albumArtist: 'Band', year: 2001);
    final album = await firstAlbum();

    final report = await editor.editAlbum(album, title: album.title, year: 2001);

    expect(tags.writes, isEmpty);
    expect(report.tracks, 0);
  });

  test('clearing the year writes an empty date', () async {
    await addTrack('1', albumArtist: 'Band', year: 2001);
    final album = await firstAlbum();

    await editor.editAlbum(album, year: 0);

    expect(tags.writes.single.update.values, {'date': ''});
    expect((await repo.albumById(album.id))!.year, isNull);
  });

  test('a locked album asks Android for permission once, not once per file', () async {
    for (final n in ['1', '2', '3', '4']) {
      await addTrack(n, albumArtist: 'Band');
    }
    tags.locked = true;

    final report = await editor.editAlbum(await firstAlbum(), title: 'Unlocked');

    expect(store.writeRequests, 1);
    expect(report.written, 4);
    expect(tags.writes.length, 4);
  });

  test('a refused permission still saves the change in the library and says so', () async {
    for (final n in ['1', '2']) {
      await addTrack(n, albumArtist: 'Band');
    }
    tags.locked = true;
    store.writeGranted = false;
    final album = await firstAlbum();

    final report = await editor.editAlbum(album, title: 'Only Here');

    expect(tags.writes, isEmpty);
    expect(report.written, 0);
    expect(report.appOnly, 2);
    expect(report.describe('Album'), contains('2 of 2 files could not be rewritten'));
    expect((await repo.albumById(album.id))!.title, 'Only Here');
  });

  test('with tag writing switched off nothing is written and the report says the edit is app-only', () async {
    await addTrack('1', albumArtist: 'Band');
    editor = await makeEditor(writeTags: false);

    final report = await editor.editAlbum(await firstAlbum(), title: 'No Files');

    expect(tags.writes, isEmpty);
    expect(report.writeEnabled, isFalse);
    expect(report.describe('Album'), 'Album saved');
    expect((await firstAlbum()).title, 'No Files');
  });

  test('renaming an artist writes artist, album artist, or both depending on the song', () async {
    // 1: artist and album artist are "Old"; 2: only the artist is "Old" (guest on a compilation);
    // 3: only the album artist is "Old" (someone else sings on Old's album).
    await addTrack('1', artist: 'Old', album: 'Own', albumArtist: 'Old');
    await addTrack('2', artist: 'Old', album: 'Comp', albumArtist: 'Various Artists');
    await addTrack('3', artist: 'Other', album: 'Duets', albumArtist: 'Old');
    final artist = (await repo.artists()).firstWhere((a) => a.name == 'Old');

    await editor.renameArtist(artist, 'New');

    Map<String, Object?> written(String n) => tags.writes.singleWhere((w) => w.uri!.endsWith('/$n')).update.values;
    expect(written('1'), {'artist': 'New', 'albumArtist': 'New'});
    expect(written('2'), {'artist': 'New'});
    expect(written('3'), {'albumArtist': 'New'});
    expect((await repo.artistById(artist.id))!.name, 'New');
    expect((await repo.trackByPath('/m/a/3.mp3'))!.albumArtist, 'New');
  });

  test('merging albums writes the target\'s title, album artist and MusicBrainz ids into the source files', () async {
    await addTrack('1', album: 'Keep', albumArtist: 'Band');
    final keep = await firstAlbum();
    await repo.updateAlbum(keep.id, mbReleaseId: 'rel-9', mbReleaseGroupId: 'grp-9');
    await repo.upsertTrack(draft('/m/b/2.mp3', 'Song 2', artist: 'Band', album: 'Fold', albumArtist: 'Band', folder: '/m/b')..contentUri = 'content://media/external/audio/media/2');
    final albums = await repo.albums();
    final source = albums.firstWhere((a) => a.title == 'Fold');
    final target = await repo.albumById(keep.id);

    await editor.mergeAlbums(source, target!);

    expect(tags.writes.single.update.values, {'album': 'Keep', 'albumArtist': 'Band', 'mbReleaseId': 'rel-9', 'mbReleaseGroupId': 'grp-9'});
    expect((await repo.albums()).single.trackCount, 2);
  });

  test('EditReport adds up for bulk edits', () {
    final sum = const EditReport(tracks: 3, written: 3) + const EditReport(tracks: 2, written: 1, id: 7);
    expect((sum.tracks, sum.written, sum.appOnly, sum.id), (5, 4, 1, 7));
  });
}
