import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';

import '../../core/library/library_repository.dart';
import '../../core/models/library_models.dart';
import '../../core/models/track.dart';
import '../../core/settings/settings_store.dart';
import '../../platform/bridges.dart';
import '../cover/image_processing.dart';
import '../metadata/tag_writer.dart';

/// What an edit did to the files behind the library rows.
class EditReport {
  const EditReport({this.tracks = 0, this.written = 0, this.writeEnabled = true, this.id});

  /// Songs the edit touched.
  final int tracks;

  /// Songs whose file tags were rewritten too.
  final int written;

  /// False when the user turned off "Write tags into files": the edit lives in the app only, on purpose.
  final bool writeEnabled;

  /// Id of the album/artist the edit resulted in (differs from the edited one after a merge).
  final int? id;

  int get appOnly => tracks - written;

  /// Totals of two reports, for bulk edits.
  EditReport operator +(EditReport other) =>
      EditReport(tracks: tracks + other.tracks, written: written + other.written, writeEnabled: writeEnabled && other.writeEnabled, id: other.id ?? id);

  /// One line for a snackbar.
  String describe(String what) {
    if (tracks == 0 || !writeEnabled) return '$what saved';
    if (appOnly == 0) return '$what saved in ${tracks == 1 ? 'the file' : 'all $tracks files'}';
    return '$what saved. $appOnly of $tracks files could not be rewritten (denied or unsupported), so those keep the change in the app only';
  }
}

/// Dashboard edits of albums and artists: changes the library rows (see [LibraryRepository]) and
/// writes the same tags into the audio files when the user allows it, so a rescan agrees.
class LibraryEditor {
  LibraryEditor({required this.repo, required this.tagWriter, required this.settings, required this.imagesDir});

  final LibraryRepository repo;
  final TagWriter tagWriter;
  final SettingsStore settings;
  final Directory Function() imagesDir;

  // ------------------------------------------------------------------ albums

  /// Only fields that differ from the album's current values are written; `null` = leave alone,
  /// `''` clears a text field, `year: 0` clears the year.
  Future<EditReport> editAlbum(Album album, {String? title, String? albumArtist, int? year, String? genre}) async {
    final newTitle = title?.trim();
    final newArtist = albumArtist?.trim();
    final changedTitle = newTitle != null && newTitle.isNotEmpty && newTitle != album.title;
    final changedArtist = newArtist != null && newArtist != (album.artistName ?? '');
    final changedYear = year != null && year != (album.year ?? 0);
    final tracks = await repo.tracks(albumId: album.id);
    final changedGenre = genre != null && tracks.any((t) => (t.genre ?? '') != genre.trim());

    final u = TagUpdate();
    if (changedTitle) u.set('album', newTitle);
    if (changedArtist) u.set('albumArtist', newArtist);
    if (changedYear) u.set('date', year <= 0 ? '' : '$year');
    if (changedGenre) u.set('genre', genre.trim());
    if (u.isEmpty) return EditReport(id: album.id, writeEnabled: settings.writeTagsToFiles);

    final written = await _write(tracks, u);
    final id = await repo.editAlbum(
      album.id,
      title: changedTitle ? newTitle : null,
      albumArtist: changedArtist ? newArtist : null,
      year: changedYear ? year : null,
      genre: changedGenre ? genre.trim() : null,
    );
    return EditReport(tracks: tracks.length, written: written, writeEnabled: settings.writeTagsToFiles, id: id);
  }

  /// Folds [source] into [target]: same title, album artist and MusicBrainz release.
  Future<EditReport> mergeAlbums(Album source, Album target) async {
    final sourceTracks = await repo.tracks(albumId: source.id);
    final targetTracks = await repo.tracks(albumId: target.id);
    final u = TagUpdate()..set('album', target.title);
    final aa = targetTracks.map((t) => t.albumArtist).firstWhere((a) => a != null && a.trim().isNotEmpty, orElse: () => null);
    if (aa != null) u.set('albumArtist', aa);
    if (target.mbReleaseId != null) u.set('mbReleaseId', target.mbReleaseId);
    if (target.mbReleaseGroupId != null) u.set('mbReleaseGroupId', target.mbReleaseGroupId);
    final written = await _write(sourceTracks, u);
    final id = await repo.mergeAlbums(source.id, target.id);
    return EditReport(tracks: sourceTracks.length, written: written, writeEnabled: settings.writeTagsToFiles, id: id);
  }

  // ----------------------------------------------------------------- artists

  /// Renames [artist] everywhere; merges into an existing artist of that name.
  Future<EditReport> renameArtist(Artist artist, String newName) async {
    final name = newName.trim();
    final tracks = await _tracksOf(artist);
    final written = await _writeArtistName(artist, tracks, name);
    final id = await repo.renameArtist(artist.id, name);
    return EditReport(tracks: tracks.length, written: written, writeEnabled: settings.writeTagsToFiles, id: id);
  }

  Future<EditReport> mergeArtists(Artist source, Artist target) async {
    final tracks = await _tracksOf(source);
    final written = await _writeArtistName(source, tracks, target.name);
    final id = await repo.mergeArtists(source.id, target.id);
    return EditReport(tracks: tracks.length, written: written, writeEnabled: settings.writeTagsToFiles, id: id);
  }

  Future<List<Track>> _tracksOf(Artist artist) async {
    final byArtist = await repo.tracks(artistId: artist.id);
    final byAlbumArtist = await repo.tracksWithAlbumArtist(artist.name);
    final seen = <int>{};
    return [
      for (final t in [...byArtist, ...byAlbumArtist])
        if (seen.add(t.id)) t,
    ];
  }

  Future<int> _writeArtistName(Artist artist, List<Track> tracks, String name) async {
    // A track can carry the artist, the album artist or both; each shape is one batched write.
    final buckets = <String, List<Track>>{};
    for (final t in tracks) {
      final isArtist = t.artistId == artist.id;
      final isAlbumArtist = (t.albumArtist ?? '').toLowerCase() == artist.name.toLowerCase();
      final shape = '${isArtist ? 'a' : ''}${isAlbumArtist ? 'b' : ''}';
      if (shape.isNotEmpty) buckets.putIfAbsent(shape, () => []).add(t);
    }
    var written = 0;
    for (final e in buckets.entries) {
      final u = TagUpdate();
      if (e.key.contains('a')) u.set('artist', name);
      if (e.key.contains('b')) u.set('albumArtist', name);
      written += await _write(e.value, u);
    }
    return written;
  }

  /// Custom photo from the gallery (square-cropped, at most 800 px).
  Future<void> setArtistPhoto(Artist artist, Uint8List bytes) async {
    final jpg = await ImageProcessing.processCoverAsync(bytes, maxSize: 800);
    final f = File('${imagesDir().path}/artist_${artist.id}.jpg')..parent.createSync(recursive: true);
    await f.writeAsBytes(jpg, flush: true);
    await repo.updateArtistFields(artist.id, {'image_path': f.path});
    evictImages();
  }

  /// The image cache is keyed by path, so a replaced file would keep showing the old picture.
  static void evictImages() {
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  }

  // ----------------------------------------------------------------- helpers

  /// Returns how many files were rewritten. Never throws: a failed write leaves the edit app-only.
  Future<int> _write(List<Track> tracks, TagUpdate update) async {
    if (!settings.writeTagsToFiles || tracks.isEmpty || update.isEmpty) return 0;
    try {
      final outcomes = await tagWriter.writeAll(tracks, update);
      return outcomes.values.where((o) => o == TagWriteOutcome.written).length;
    } on PlatformFailure {
      return 0;
    }
  }
}
