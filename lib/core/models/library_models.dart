import 'dart:convert';

class Artist {
  const Artist({
    required this.id,
    required this.name,
    this.sortName,
    this.mbArtistId,
    this.imagePath,
    this.imageUrl,
    this.bio,
    this.bioSource,
    this.infoFetchedAt,
    this.followed = false,
    this.lastReleaseCheck,
    this.trackCount = 0,
    this.albumCount = 0,
  });

  final int id;
  final String name;
  final String? sortName;
  final String? mbArtistId;
  final String? imagePath;
  final String? imageUrl;
  final String? bio;
  final String? bioSource;
  final int? infoFetchedAt;
  final bool followed;
  final int? lastReleaseCheck;
  final int trackCount;
  final int albumCount;

  factory Artist.fromMap(Map<String, Object?> m) => Artist(
        id: m['id'] as int,
        name: m['name'] as String,
        sortName: m['sort_name'] as String?,
        mbArtistId: m['mb_artist_id'] as String?,
        imagePath: m['image_path'] as String?,
        imageUrl: m['image_url'] as String?,
        bio: m['bio'] as String?,
        bioSource: m['bio_source'] as String?,
        infoFetchedAt: m['info_fetched_at'] as int?,
        followed: ((m['followed'] as int?) ?? 0) != 0,
        lastReleaseCheck: m['last_release_check'] as int?,
        trackCount: (m['track_count'] as int?) ?? 0,
        albumCount: (m['album_count'] as int?) ?? 0,
      );
}

class Album {
  const Album({
    required this.id,
    required this.title,
    required this.groupKey,
    this.artistId,
    this.artistName,
    this.year,
    this.mbReleaseId,
    this.mbReleaseGroupId,
    this.coverPath,
    this.coverSource,
    this.compilation = false,
    this.trackCount = 0,
    this.durationMs = 0,
  });

  final int id;
  final String title;
  final String groupKey;
  final int? artistId;
  final String? artistName;
  final int? year;
  final String? mbReleaseId;
  final String? mbReleaseGroupId;
  final String? coverPath;
  final String? coverSource;
  final bool compilation;
  final int trackCount;
  final int durationMs;

  String get displayArtist => (artistName == null || artistName!.isEmpty) ? 'Unknown artist' : artistName!;

  factory Album.fromMap(Map<String, Object?> m) => Album(
        id: m['id'] as int,
        title: m['title'] as String,
        groupKey: m['group_key'] as String,
        artistId: m['artist_id'] as int?,
        artistName: m['artist_name'] as String?,
        year: m['year'] as int?,
        mbReleaseId: m['mb_release_id'] as String?,
        mbReleaseGroupId: m['mb_release_group_id'] as String?,
        coverPath: m['cover_path'] as String?,
        coverSource: m['cover_source'] as String?,
        compilation: ((m['compilation'] as int?) ?? 0) != 0,
        trackCount: (m['track_count'] as int?) ?? 0,
        durationMs: (m['total_duration'] as int?) ?? 0,
      );
}

/// Headline numbers for the dashboard.
class LibraryStats {
  const LibraryStats({
    this.tracks = 0,
    this.albums = 0,
    this.artists = 0,
    this.durationMs = 0,
    this.sizeBytes = 0,
    this.identified = 0,
    this.loved = 0,
  });

  final int tracks;
  final int albums;
  final int artists;
  final int durationMs;
  final int sizeBytes;
  final int identified;
  final int loved;

  /// Share of songs matched to MusicBrainz, 0..1.
  double get identifiedRatio => tracks == 0 ? 0 : identified / tracks;
}

class Playlist {
  const Playlist({
    required this.id,
    required this.name,
    required this.isSmart,
    required this.createdAt,
    required this.updatedAt,
    this.smartRules,
    this.trackCount = 0,
  });

  final int id;
  final String name;
  final bool isSmart;
  final String? smartRules;
  final int createdAt;
  final int updatedAt;
  final int trackCount;

  factory Playlist.fromMap(Map<String, Object?> m) => Playlist(
        id: m['id'] as int,
        name: m['name'] as String,
        isSmart: ((m['is_smart'] as int?) ?? 0) != 0,
        smartRules: m['smart_rules'] as String?,
        createdAt: m['created_at'] as int,
        updatedAt: m['updated_at'] as int,
        trackCount: (m['track_count'] as int?) ?? 0,
      );
}

class LyricsRow {
  const LyricsRow({
    required this.id,
    required this.trackId,
    required this.source,
    required this.fetchedAt,
    this.plainText,
    this.syncedLrc,
    this.instrumental = false,
  });

  final int id;
  final int trackId;
  final String? plainText;
  final String? syncedLrc;
  final String? source;
  final bool instrumental;
  final int fetchedAt;

  bool get hasSynced => syncedLrc != null && syncedLrc!.trim().isNotEmpty;
  bool get hasAny => hasSynced || (plainText != null && plainText!.trim().isNotEmpty);

  factory LyricsRow.fromMap(Map<String, Object?> m) => LyricsRow(
        id: m['id'] as int,
        trackId: m['track_id'] as int,
        plainText: m['plain_text'] as String?,
        syncedLrc: m['synced_lrc'] as String?,
        source: m['source'] as String?,
        instrumental: ((m['instrumental'] as int?) ?? 0) != 0,
        fetchedAt: m['fetched_at'] as int,
      );
}

enum JobStatus {
  queued,
  running,
  postprocessing,
  done,
  failed,
  cancelled;

  static JobStatus parse(String? s) =>
      JobStatus.values.firstWhere((e) => e.name == s, orElse: () => JobStatus.queued);

  bool get isActive => this == queued || this == running || this == postprocessing;
}

class DownloadJob {
  const DownloadJob({
    required this.id,
    required this.url,
    required this.sourceType,
    required this.status,
    required this.createdAt,
    this.title,
    this.artist,
    this.thumbnail,
    this.progress = 0,
    this.stage,
    this.outputPath,
    this.trackId,
    this.error,
    this.log,
    this.finishedAt,
    this.options = const {},
  });

  final int id;
  final String url;
  final String sourceType;
  final String? title;
  final String? artist;
  final String? thumbnail;
  final JobStatus status;
  final double progress;
  final String? stage;
  final String? outputPath;
  final int? trackId;
  final String? error;
  final String? log;
  final int createdAt;
  final int? finishedAt;
  final Map<String, dynamic> options;

  factory DownloadJob.fromMap(Map<String, Object?> m) => DownloadJob(
        id: m['id'] as int,
        url: m['url'] as String,
        sourceType: m['source_type'] as String,
        title: m['title'] as String?,
        artist: m['artist'] as String?,
        thumbnail: m['thumbnail'] as String?,
        status: JobStatus.parse(m['status'] as String?),
        progress: (m['progress'] as num?)?.toDouble() ?? 0,
        stage: m['stage'] as String?,
        outputPath: m['output_path'] as String?,
        trackId: m['track_id'] as int?,
        error: m['error'] as String?,
        log: m['log'] as String?,
        createdAt: m['created_at'] as int,
        finishedAt: m['finished_at'] as int?,
        options: (m['options'] as String?) == null
            ? const {}
            : (jsonDecode(m['options'] as String) as Map).cast<String, dynamic>(),
      );
}

class WishlistItem {
  const WishlistItem({
    required this.id,
    required this.artist,
    required this.title,
    required this.status,
    required this.createdAt,
    this.album,
    this.isrc,
    this.origin,
    this.jobId,
  });

  final int id;
  final String artist;
  final String title;
  final String? album;
  final String? isrc;
  final String? origin;
  final String status;
  final int? jobId;
  final int createdAt;

  factory WishlistItem.fromMap(Map<String, Object?> m) => WishlistItem(
        id: m['id'] as int,
        artist: m['artist'] as String,
        title: m['title'] as String,
        album: m['album'] as String?,
        isrc: m['isrc'] as String?,
        origin: m['origin'] as String?,
        status: m['status'] as String,
        jobId: m['job_id'] as int?,
        createdAt: m['created_at'] as int,
      );
}
