import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/core/library/library_repository.dart';

import 'helpers/test_db.dart';
import 'library_repository_test.dart' show draft;

void main() {
  late LibraryRepository repo;

  setUp(() async {
    repo = await openTestRepo();
  });

  tearDown(() async => repo.appDb.close());

  Future<int> albumIdOf(String path) async => (await repo.trackByPath(path))!.albumId!;

  group('editAlbum', () {
    test('renames in place, keeps the id and cover, and later scans land in the same album', () async {
      await repo.upsertTrack(draft('/m/a/1.mp3', 'One', artist: 'Band', album: 'Frist', albumArtist: 'Band', no: 1));
      await repo.upsertTrack(draft('/m/a/2.mp3', 'Two', artist: 'Band', album: 'Frist', albumArtist: 'Band', no: 2));
      final id = await albumIdOf('/m/a/1.mp3');
      await repo.updateAlbum(id, coverPath: '/covers/a.jpg', coverSource: 'manual');

      final result = await repo.editAlbum(id, title: 'First');

      expect(result, id);
      final album = (await repo.albumById(id))!;
      expect(album.title, 'First');
      expect(album.coverPath, '/covers/a.jpg');
      expect((await repo.tracks(albumId: id)).map((t) => t.albumTitle).toSet(), {'First'});
      expect((await repo.searchTracks('first')).length, 2);

      // the file tags were rewritten to the same values, so a rescan must not fork a new album
      await repo.upsertTrack(draft('/m/a/1.mp3', 'One', artist: 'Band', album: 'First', albumArtist: 'Band', no: 1));
      expect((await repo.albums()).length, 1);
      expect(await albumIdOf('/m/a/1.mp3'), id);
    });

    test('renames an album that is keyed by a MusicBrainz release', () async {
      await repo.upsertTrack(draft('/m/a/1.mp3', 'One', artist: 'Band', album: 'Wrong'));
      final tid = (await repo.trackByPath('/m/a/1.mp3'))!.id;
      await repo.updateTrackColumns(tid, {'mb_release_id': 'rel-1'});
      await repo.upsertTrack(draft('/m/a/1.mp3', 'One', artist: 'Band', album: 'Wrong')..mbReleaseId = 'rel-1');
      final id = await albumIdOf('/m/a/1.mp3');

      await repo.editAlbum(id, title: 'Right');

      expect((await repo.albumById(id))!.title, 'Right');
      expect((await repo.albums()).length, 1);
    });

    test('merges into an existing album when the new identity already exists', () async {
      await repo.upsertTrack(draft('/m/a/1.mp3', 'One', artist: 'Band', album: 'Live', albumArtist: 'Band'));
      await repo.upsertTrack(draft('/m/b/2.mp3', 'Two', artist: 'Band', album: 'Live (Deluxe)', albumArtist: 'Band', folder: '/m/b'));
      final keep = await albumIdOf('/m/a/1.mp3');
      final fold = await albumIdOf('/m/b/2.mp3');
      await repo.updateAlbum(fold, coverPath: '/covers/fold.jpg');

      final result = await repo.editAlbum(fold, title: 'Live');

      expect(result, keep);
      expect((await repo.albums()).single.trackCount, 2);
      expect((await repo.albumById(keep))!.coverPath, '/covers/fold.jpg', reason: 'cover moves to a target that has none');
      expect(await repo.albumById(fold), isNull);
    });

    test('sets and clears year, applies genre, and can turn an album into a compilation', () async {
      await repo.upsertTrack(draft('/m/a/1.mp3', 'One', artist: 'A', album: 'Mix', year: 1999));
      await repo.upsertTrack(draft('/m/a/2.mp3', 'Two', artist: 'A', album: 'Mix', year: 2003));
      final id = await albumIdOf('/m/a/1.mp3');

      await repo.editAlbum(id, year: 2010, genre: 'Jazz');
      var album = (await repo.albumById(id))!;
      expect(album.year, 2010);
      expect((await repo.tracks(albumId: id)).every((t) => t.genre == 'Jazz' && t.year == 2010), isTrue);

      await repo.editAlbum(id, year: 0);
      expect((await repo.albumById(id))!.year, isNull);

      await repo.editAlbum(id, albumArtist: 'Various Artists');
      album = (await repo.albumById(id))!;
      expect(album.compilation, isTrue);
      expect(album.displayArtist, 'Various Artists');
      expect(album.artistId, isNull);
    });
  });

  group('artists', () {
    test('rename updates tracks, albums, group keys and search, without forking albums on rescan', () async {
      await repo.upsertTrack(draft('/m/a/1.mp3', 'One', artist: 'Beyonce', album: 'Lemonade', albumArtist: 'Beyonce'));
      final artistId = (await repo.trackByPath('/m/a/1.mp3'))!.artistId!;

      final result = await repo.renameArtist(artistId, 'Beyoncé');

      expect(result, artistId);
      final artists = await repo.artists();
      expect(artists.single.name, 'Beyoncé');
      expect(artists.single.trackCount, 1);
      final t = (await repo.trackByPath('/m/a/1.mp3'))!;
      expect(t.artistName, 'Beyoncé');
      expect(t.albumArtist, 'Beyoncé');
      expect((await repo.albums()).single.displayArtist, 'Beyoncé');
      expect((await repo.searchTracks('Beyoncé')).length, 1);

      await repo.upsertTrack(draft('/m/a/2.mp3', 'Two', artist: 'Beyoncé', album: 'Lemonade', albumArtist: 'Beyoncé'));
      expect((await repo.albums()).length, 1);
      expect((await repo.artists()).length, 1);
    });

    test('renaming to an existing name merges the two artists', () async {
      await repo.upsertTrack(draft('/m/a/1.mp3', 'One', artist: 'AC DC', album: 'Highway', albumArtist: 'AC DC'));
      await repo.upsertTrack(draft('/m/b/2.mp3', 'Two', artist: 'AC/DC', album: 'Back in Black', albumArtist: 'AC/DC', folder: '/m/b'));
      final dup = (await repo.trackByPath('/m/a/1.mp3'))!.artistId!;
      final keep = (await repo.trackByPath('/m/b/2.mp3'))!.artistId!;
      await repo.updateArtist(dup, followed: true, bio: 'Australian rock band');

      final result = await repo.renameArtist(dup, 'AC/DC');

      expect(result, keep);
      final artists = await repo.artists();
      expect(artists.single.name, 'AC/DC');
      expect(artists.single.trackCount, 2);
      expect(artists.single.albumCount, 2);
      expect(artists.single.followed, isTrue, reason: 'follow flag survives the merge');
      expect(artists.single.bio, 'Australian rock band');
      expect((await repo.albums()).every((a) => a.artistId == keep), isTrue);
    });

    test('mergeArtists keeps the survivor\'s own info', () async {
      await repo.upsertTrack(draft('/m/a/1.mp3', 'One', artist: 'Queen', album: 'A', folder: '/m/a'));
      await repo.upsertTrack(draft('/m/b/2.mp3', 'Two', artist: 'Queen Band', album: 'B', folder: '/m/b'));
      final source = (await repo.trackByPath('/m/b/2.mp3'))!.artistId!;
      final target = (await repo.trackByPath('/m/a/1.mp3'))!.artistId!;
      await repo.updateArtist(target, bio: 'Target bio');
      await repo.updateArtist(source, bio: 'Source bio', mbArtistId: 'mb-1');

      await repo.mergeArtists(source, target);

      final a = (await repo.artistById(target))!;
      expect(a.bio, 'Target bio');
      expect(a.mbArtistId, 'mb-1');
      expect(await repo.artistById(source), isNull);
      expect((await repo.tracks(artistId: target)).length, 2);
    });

    test('a blank name is rejected', () async {
      await repo.upsertTrack(draft('/m/a/1.mp3', 'One', artist: 'Someone', album: 'A'));
      final id = (await repo.trackByPath('/m/a/1.mp3'))!.artistId!;
      expect(() => repo.renameArtist(id, '   '), throwsArgumentError);
    });

    test('updateArtistFields can clear a column', () async {
      await repo.upsertTrack(draft('/m/a/1.mp3', 'One', artist: 'Someone', album: 'A'));
      final id = (await repo.trackByPath('/m/a/1.mp3'))!.artistId!;
      await repo.updateArtist(id, bio: 'hello');
      await repo.updateArtistFields(id, {'bio': null});
      expect((await repo.artistById(id))!.bio, isNull);
    });
  });

  test('mergeAlbums moves tracks under the target and drops the source', () async {
    await repo.upsertTrack(draft('/m/a/1.mp3', 'One', artist: 'Band', album: 'Album', albumArtist: 'Band', no: 1));
    await repo.upsertTrack(draft('/m/b/2.mp3', 'Two', artist: 'Band', album: 'Album pt2', albumArtist: 'Band', no: 2, folder: '/m/b'));
    final target = await albumIdOf('/m/a/1.mp3');
    final source = await albumIdOf('/m/b/2.mp3');

    await repo.mergeAlbums(source, target);

    final albums = await repo.albums();
    expect(albums.single.id, target);
    expect(albums.single.trackCount, 2);
    expect((await repo.tracks(albumId: target)).map((t) => t.albumTitle).toSet(), {'Album'});
  });

  test('stats and top artists summarise the library', () async {
    await repo.upsertTrack(draft('/m/a/1.mp3', 'One', artist: 'A', album: 'X', mbRecording: 'r1'));
    await repo.upsertTrack(draft('/m/a/2.mp3', 'Two', artist: 'A', album: 'X'));
    await repo.upsertTrack(draft('/m/b/3.mp3', 'Three', artist: 'B', album: 'Y', folder: '/m/b'));
    await repo.setLoved((await repo.trackByPath('/m/a/1.mp3'))!.id, true);

    final s = await repo.stats();
    expect((s.tracks, s.albums, s.artists, s.identified, s.loved), (3, 2, 2, 1, 1));
    expect(s.durationMs, 600000);
    expect(s.identifiedRatio, closeTo(1 / 3, 1e-9));
    final top = await repo.topArtists(limit: 1);
    expect((top.single.name, top.single.count), ('A', 2));
  });
}
