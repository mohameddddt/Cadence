import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../core/library/library_repository.dart';
import '../../core/models/library_models.dart';
import '../../core/models/track.dart';
import '../../core/settings/settings_store.dart';
import '../../core/util/filename_template.dart';
import '../../platform/bridges.dart';
import '../cover/cover_service.dart';
import '../lyrics/lyrics_service.dart';
import '../metadata/identify_service.dart';
import '../metadata/tag_writer.dart';
import '../metadata/title_cleaner.dart';
import '../playback/loudness_service.dart';
import 'download_models.dart';
import 'engines.dart';
import 'job_repository.dart';
import 'source_detect.dart';

class PipelineResult {
  const PipelineResult({this.track, this.duplicateOf, this.notes = const []});

  final Track? track;

  /// The download matched an existing library track and was discarded.
  final Track? duplicateOf;
  final List<String> notes;
}

/// Everything that happens between "yt-dlp finished" and "the track is in the library"
/// (plan 3.5 step 4): tag, move into MediaStore, identify, cover, lyrics, ReplayGain.
class DownloadPipeline {
  DownloadPipeline({
    required this.repo,
    required this.jobs,
    required this.bridges,
    required this.settings,
    required this.identify,
    required this.covers,
    required this.lyrics,
    required this.loudness,
  });

  final LibraryRepository repo;
  final JobRepository jobs;
  final Bridges bridges;
  final SettingsStore settings;
  final IdentifyService identify;
  final CoverService covers;
  final LyricsService lyrics;
  final LoudnessService loudness;

  static const Map<String, String> mimeByExt = {
    'mp3': 'audio/mpeg',
    'm4a': 'audio/mp4',
    'aac': 'audio/aac',
    'flac': 'audio/flac',
    'ogg': 'audio/ogg',
    'oga': 'audio/ogg',
    'opus': 'audio/ogg',
    'wav': 'audio/x-wav',
    'webm': 'audio/webm',
    'weba': 'audio/webm',
    'mka': 'audio/x-matroska',
  };

  Future<PipelineResult> process(DownloadJob job, EngineResult result, {RemoteHint? hint}) async {
    final notes = <String>[];
    final file = result.files.first;
    final ext = file.path.contains('.') ? file.path.substring(file.path.lastIndexOf('.') + 1).toLowerCase() : 'm4a';
    final sourceInfo = detectSource(job.url);
    // Direct downloads (Internet Archive files...) carry their own unique identity.
    final canonical = (job.options['canonical'] as String?) ?? sourceInfo.canonicalUrl;

    Future<void> stage(String s, {double? progress}) => jobs.update(job.id, status: JobStatus.postprocessing, stage: s, progress: progress, notify: true);

    // ---- 1. read what we know ------------------------------------------------
    await stage('Reading tags');
    TagData? tags;
    try {
      tags = await bridges.tags.read(path: file.path);
    } on PlatformFailure {
      tags = null;
    }
    final info = result.info == null ? null : MediaInfo.fromJson(result.info!, fallbackUrl: job.url);
    final cleaner = TitleCleaner.fromSettings(settings.titleRules);
    final rawTitle = info?.title ?? tags?.title ?? hint?.title ?? job.title ?? file.path.split(RegExp(r'[\\/]')).last;
    final cleaned = cleaner.clean(rawTitle, uploader: info?.uploader ?? hint?.artist);

    final title = _first([info?.track, hint?.trackTitle, cleaned.title]) ?? rawTitle;
    final artist = _first([
          info?.artist,
          hint?.artist,
          cleaned.artist,
          _channelArtist(sourceInfo.source, info?.uploader),
        ]) ??
        (tags?.artist);
    final album = _first([info?.album, hint?.album, tags?.album]);
    final year = info?.releaseYear ?? hint?.year ?? tags?.year;
    final durationMs = (tags?.durationMs ?? 0) > 0 ? tags!.durationMs! : (info?.durationSec ?? 0) * 1000;

    // ---- 2. duplicates ---------------------------------------------------------
    await stage('Checking for duplicates');
    final hash = await _hash(file);
    if (job.options['force'] != true) {
      final dup = await repo.findDuplicate(sourceUrl: canonical, audioHash: hash);
      if (dup != null) {
        _deleteQuietly(file);
        return PipelineResult(duplicateOf: dup, notes: ['Already in your library']);
      }
    }

    // ---- 3. tag the temp file, then move it into the music collection -----------
    await stage('Writing tags');
    final update = TagUpdate({
      'title': title,
      if (artist != null) 'artist': artist,
      if (album != null) 'album': album,
      if (year != null) 'date': '$year',
      'sourceUrl': canonical,
      'comment': canonical,
      if (cleaned.featured.isNotEmpty && artist != null) 'artist': '$artist feat. ${cleaned.featured.join(', ')}',
    });
    try {
      // The temp file lives in our cache directory: we own it, so this is a direct write.
      await bridges.tags.write(path: file.path, update: update);
    } on PlatformFailure catch (e) {
      if (!e.unsupportedFormat) notes.add('Could not write tags: ${e.message}');
    }

    await stage('Adding to library');
    final relative = _relativePath(title: title, artist: artist, album: album, year: year, track: info?.trackNumber ?? hint?.trackNumber ?? tags?.trackNo, source: sourceInfo.source);
    final segments = relative.split('/');
    final displayName = '${segments.last}.$ext';
    final relativeDir = [settings.downloadFolder, ...segments.take(segments.length - 1)].join('/');
    final inserted = await bridges.mediaStore.insertAudio(
      src: file.path,
      displayName: displayName,
      relativeDir: relativeDir,
      mime: mimeByExt[ext] ?? 'audio/mpeg',
    );
    _deleteQuietly(file);

    // ---- 4. library row ------------------------------------------------------------
    FileStat2? stat;
    try {
      stat = await bridges.tags.stat(path: inserted.path, uri: inserted.uri);
    } on PlatformFailure {
      stat = null;
    }
    TagData? finalTags;
    try {
      finalTags = await bridges.tags.read(path: inserted.path, uri: inserted.uri);
    } on PlatformFailure {
      finalTags = null;
    }
    final key = inserted.path ?? inserted.uri;
    final draft = TrackDraft(
      filePath: key,
      contentUri: inserted.uri,
      folder: inserted.path != null && inserted.path!.contains('/') ? inserted.path!.substring(0, inserted.path!.lastIndexOf('/')) : null,
      title: title,
      artist: artist,
      album: album,
      trackNo: info?.trackNumber ?? tags?.trackNo,
      durationMs: durationMs,
      year: year,
      genre: tags?.genre,
      bitrate: tags?.bitrate,
      format: ext.toUpperCase(),
      sizeBytes: stat?.size ?? 0,
      fileMtime: stat?.lastModified ?? 0,
      source: sourceInfo.source == TrackSource.other ? (hint?.source ?? TrackSource.other) : sourceInfo.source,
      sourceUrl: canonical,
      audioHash: hash,
      hasEmbeddedArt: finalTags?.hasArt ?? tags?.hasArt ?? false,
    );
    final trackId = await repo.upsertTrack(draft);
    var track = (await repo.trackById(trackId))!;
    await jobs.update(job.id, trackId: trackId, outputPath: key);

    // ---- 5. identify -------------------------------------------------------------
    if (settings.autoIdentify) {
      await stage('Identifying');
      try {
        final r = await identify.identify(track, onStage: (s) => stage(s));
        notes.addAll(r.notes);
        if (r.autoAccept) {
          final outcome = await identify.apply(track, r.best!);
          notes.add('Matched: ${r.best!.summary}');
          if (outcome != TagWriteOutcome.written && settings.writeTagsToFiles) notes.add('Tags saved in the app only ($outcome)');
        } else if (r.candidates.isNotEmpty) {
          await identify.markNeedsReview(track);
          notes.add('Possible match found - review it in Fix tags');
        }
        track = (await repo.trackById(trackId)) ?? track;
      } on Exception catch (e) {
        notes.add('Identification failed: $e');
      }
    }

    // ---- 6. cover -------------------------------------------------------------------
    if (settings.autoCover) {
      await stage('Fetching cover');
      try {
        var current = track;
        if (await covers.normalizeEmbedded(current)) {
          current = (await repo.trackById(trackId)) ?? current;
        }
        var found = false;
        if (current.albumId != null) {
          final album = await repo.albumById(current.albumId!);
          if (album != null) {
            final f = await covers.ensureAlbumCover(album);
            final fresh = await repo.albumById(album.id);
            found = f != null;
            // An online cover replaces whatever the file had; an "embedded" cover came from the
            // file itself and is already in place.
            if (f != null && fresh?.coverSource != 'embedded') await covers.embedInto(current, f);
          }
        }
        // No album art anywhere: fall back to the video's own thumbnail (cropped square).
        final thumb = info?.thumbnail ?? job.thumbnail ?? hint?.thumbnail;
        if (!found && !current.hasEmbeddedArt && thumb != null) {
          await covers.useThumbnail(current, thumb);
        }
        track = (await repo.trackById(trackId)) ?? track;
      } on Exception catch (e) {
        notes.add('Cover failed: $e');
      }
    }

    // ---- 7. lyrics -----------------------------------------------------------------------
    if (settings.autoLyrics) {
      await stage('Fetching lyrics');
      try {
        await lyrics.lyricsFor(track);
      } on Exception catch (e) {
        notes.add('Lyrics failed: $e');
      }
    }

    // ---- 8. replaygain ---------------------------------------------------------------
    if (settings.autoReplayGain) {
      await stage('Measuring loudness');
      try {
        await loudness.analyzeAndStore(track, writeTags: settings.writeTagsToFiles);
      } on Exception catch (e) {
        notes.add('ReplayGain failed: $e');
      }
    }

    // ---- 9. organise -----------------------------------------------------------------------
    track = (await repo.trackById(trackId)) ?? track;
    if (settings.organizeFiles && track.identifyState == IdentifyState.matched && track.contentUri != null) {
      try {
        track = await _organize(track, ext);
      } on PlatformFailure catch (e) {
        notes.add('Could not rename into the album folder: ${e.message}');
      }
    }
    return PipelineResult(track: track, notes: notes);
  }

  /// Moves the file to `Artist/Album/NN - Title` after the tags were corrected.
  Future<Track> _organize(Track t, String ext) async {
    final rel = _relativePath(title: t.title, artist: t.artistName, album: t.albumTitle, year: t.year, track: t.trackNo, source: t.source);
    final segs = rel.split('/');
    final name = '${segs.last}.$ext';
    final dir = [settings.downloadFolder, ...segs.take(segs.length - 1)].join('/');
    final wanted = '/$dir/$name'.replaceAll('//', '/');
    if (t.hasRealPath && t.filePath.endsWith(wanted)) return t; // already there
    final moved = await bridges.mediaStore.moveAudio(uri: t.contentUri!, relativeDir: dir, displayName: name);
    final newKey = moved.path ?? t.filePath;
    await repo.updateTrackColumns(t.id, {
      'file_path': newKey,
      'folder': moved.path != null && moved.path!.contains('/') ? moved.path!.substring(0, moved.path!.lastIndexOf('/')) : t.folder,
    });
    return (await repo.trackById(t.id)) ?? t;
  }

  String _relativePath({required String title, String? artist, String? album, int? year, int? track, required TrackSource source}) {
    return FilenameTemplate(settings.filenameTemplate).render({
      'title': title,
      'artist': artist,
      'albumartist': artist,
      'album': album,
      'track': track,
      'year': year,
      'source': source.label,
    });
  }

  static String? _first(Iterable<String?> values) {
    for (final v in values) {
      if (v != null && v.trim().isNotEmpty) return v.trim();
    }
    return null;
  }

  /// A channel name is a plausible artist on SoundCloud/Bandcamp/Audius, and on YouTube only
  /// for auto-generated "- Topic" and VEVO channels.
  static String? _channelArtist(TrackSource source, String? uploader) {
    if (uploader == null || uploader.trim().isEmpty) return null;
    final isYouTube = source == TrackSource.youtube || source == TrackSource.youtubeMusic;
    if (isYouTube) {
      final cleaned = TitleCleaner.cleanChannel(uploader);
      return cleaned != uploader.trim() ? cleaned : null;
    }
    return uploader.trim();
  }

  Future<String> _hash(File f) async => (await sha1.bind(f.openRead()).first).toString();

  void _deleteQuietly(File f) {
    try {
      if (f.existsSync()) f.deleteSync();
    } on FileSystemException {
      // temp dir is cleaned up anyway
    }
  }
}

/// Metadata supplied by a [SourceProvider] (direct downloads have no info json).
class RemoteHint {
  const RemoteHint({this.title, this.trackTitle, this.artist, this.album, this.year, this.trackNumber, this.source, this.thumbnail});

  final String? thumbnail;

  Map<String, dynamic> toJson() => {
        if (title != null) 'title': title,
        if (trackTitle != null) 'trackTitle': trackTitle,
        if (artist != null) 'artist': artist,
        if (album != null) 'album': album,
        if (year != null) 'year': year,
        if (trackNumber != null) 'trackNumber': trackNumber,
        if (source != null) 'source': source!.name,
        if (thumbnail != null) 'thumbnail': thumbnail,
      };

  factory RemoteHint.fromJson(Map<String, dynamic> j) => RemoteHint(
        title: j['title'] as String?,
        trackTitle: j['trackTitle'] as String?,
        artist: j['artist'] as String?,
        album: j['album'] as String?,
        year: (j['year'] as num?)?.toInt(),
        trackNumber: (j['trackNumber'] as num?)?.toInt(),
        source: j['source'] == null ? null : TrackSource.parse(j['source'] as String?),
        thumbnail: j['thumbnail'] as String?,
      );

  final String? title;
  final String? trackTitle;
  final String? artist;
  final String? album;
  final int? year;
  final int? trackNumber;
  final TrackSource? source;
}
