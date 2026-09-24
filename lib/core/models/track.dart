/// Where a track came from. Stored as [name] in tracks.source.
enum TrackSource {
  local,
  youtube,
  youtubeMusic,
  soundcloud,
  internetArchive,
  bandcamp,
  audius,
  jamendo,
  ccmixter,
  mixcloud,
  vimeo,
  twitch,
  podcast,
  other;

  static TrackSource parse(String? s) =>
      TrackSource.values.firstWhere((e) => e.name == s, orElse: () => TrackSource.other);

  String get label => switch (this) {
        TrackSource.local => 'Local',
        TrackSource.youtube => 'YouTube',
        TrackSource.youtubeMusic => 'YouTube Music',
        TrackSource.soundcloud => 'SoundCloud',
        TrackSource.internetArchive => 'Internet Archive',
        TrackSource.bandcamp => 'Bandcamp',
        TrackSource.audius => 'Audius',
        TrackSource.jamendo => 'Jamendo',
        TrackSource.ccmixter => 'ccMixter',
        TrackSource.mixcloud => 'Mixcloud',
        TrackSource.vimeo => 'Vimeo',
        TrackSource.twitch => 'Twitch',
        TrackSource.podcast => 'Podcast',
        TrackSource.other => 'Other',
      };
}

/// Result of fingerprint/text matching for a track.
class IdentifyState {
  const IdentifyState._();
  static const int unmatched = 0;
  static const int matched = 1;
  static const int needsReview = 2;
  static const int skipped = 3;
}

class Track {
  const Track({
    required this.id,
    required this.filePath,
    required this.title,
    required this.dateAdded,
    this.contentUri,
    this.folder,
    this.artistId,
    this.artistName,
    this.albumArtist,
    this.albumId,
    this.albumTitle,
    this.trackNo,
    this.discNo,
    this.durationMs = 0,
    this.year,
    this.genre,
    this.bitrate,
    this.format,
    this.sizeBytes = 0,
    this.fileMtime = 0,
    this.lastPlayed,
    this.playCount = 0,
    this.rating = 0,
    this.loved = false,
    this.source = TrackSource.local,
    this.sourceUrl,
    this.mbRecordingId,
    this.mbReleaseId,
    this.mbReleaseGroupId,
    this.mbArtistId,
    this.acoustId,
    this.isrc,
    this.replayGainTrack,
    this.replayGainAlbum,
    this.lyricsId,
    this.lyricsOffsetMs = 0,
    this.audioHash,
    this.identifyState = IdentifyState.unmatched,
    this.identifyScore,
    this.hasEmbeddedArt = false,
    this.missing = false,
  });

  final int id;
  final String filePath;
  final String? contentUri;
  final String? folder;
  final String title;
  final int? artistId;
  final String? artistName;
  final String? albumArtist;
  final int? albumId;
  final String? albumTitle;
  final int? trackNo;
  final int? discNo;
  final int durationMs;
  final int? year;
  final String? genre;
  final int? bitrate;
  final String? format;
  final int sizeBytes;
  final int fileMtime;
  final int dateAdded;
  final int? lastPlayed;
  final int playCount;
  final int rating;
  final bool loved;
  final TrackSource source;
  final String? sourceUrl;
  final String? mbRecordingId;
  final String? mbReleaseId;
  final String? mbReleaseGroupId;
  final String? mbArtistId;
  final String? acoustId;
  final String? isrc;
  final double? replayGainTrack;
  final double? replayGainAlbum;
  final int? lyricsId;
  final int lyricsOffsetMs;
  final String? audioHash;
  final int identifyState;
  final double? identifyScore;
  final bool hasEmbeddedArt;
  final bool missing;

  Duration get duration => Duration(milliseconds: durationMs);

  String get displayArtist => (artistName == null || artistName!.isEmpty) ? 'Unknown artist' : artistName!;

  String get displayAlbum => (albumTitle == null || albumTitle!.isEmpty) ? 'Unknown album' : albumTitle!;

  /// Real filesystem path (as opposed to a SAF document URI used as the key).
  bool get hasRealPath => !_uriScheme.hasMatch(filePath);
  static final RegExp _uriScheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*://');

  /// What to hand to the player: prefer the file when it is a real path.
  Uri get playUri => hasRealPath ? Uri.file(filePath) : Uri.parse(contentUri ?? filePath);

  bool get isIdentified => mbRecordingId != null && mbRecordingId!.isNotEmpty;

  factory Track.fromMap(Map<String, Object?> m) => Track(
        id: m['id'] as int,
        filePath: m['file_path'] as String,
        contentUri: m['content_uri'] as String?,
        folder: m['folder'] as String?,
        title: m['title'] as String,
        artistId: m['artist_id'] as int?,
        artistName: m['artist_name'] as String?,
        albumArtist: m['album_artist'] as String?,
        albumId: m['album_id'] as int?,
        albumTitle: m['album_title'] as String?,
        trackNo: m['track_no'] as int?,
        discNo: m['disc_no'] as int?,
        durationMs: (m['duration_ms'] as int?) ?? 0,
        year: m['year'] as int?,
        genre: m['genre'] as String?,
        bitrate: m['bitrate'] as int?,
        format: m['format'] as String?,
        sizeBytes: (m['size_bytes'] as int?) ?? 0,
        fileMtime: (m['file_mtime'] as int?) ?? 0,
        dateAdded: m['date_added'] as int,
        lastPlayed: m['last_played'] as int?,
        playCount: (m['play_count'] as int?) ?? 0,
        rating: (m['rating'] as int?) ?? 0,
        loved: ((m['loved'] as int?) ?? 0) != 0,
        source: TrackSource.parse(m['source'] as String?),
        sourceUrl: m['source_url'] as String?,
        mbRecordingId: m['mb_recording_id'] as String?,
        mbReleaseId: m['mb_release_id'] as String?,
        mbReleaseGroupId: m['mb_release_group_id'] as String?,
        mbArtistId: m['mb_artist_id'] as String?,
        acoustId: m['acoustid'] as String?,
        isrc: m['isrc'] as String?,
        replayGainTrack: (m['replay_gain_track'] as num?)?.toDouble(),
        replayGainAlbum: (m['replay_gain_album'] as num?)?.toDouble(),
        lyricsId: m['lyrics_id'] as int?,
        lyricsOffsetMs: (m['lyrics_offset_ms'] as int?) ?? 0,
        audioHash: m['audio_hash'] as String?,
        identifyState: (m['identify_state'] as int?) ?? 0,
        identifyScore: (m['identify_score'] as num?)?.toDouble(),
        hasEmbeddedArt: ((m['has_embedded_art'] as int?) ?? 0) != 0,
        missing: ((m['missing'] as int?) ?? 0) != 0,
      );
}

/// Everything the scanner or downloader knows about a file before it has a row.
class TrackDraft {
  TrackDraft({
    required this.filePath,
    required this.title,
    this.contentUri,
    this.folder,
    this.artist,
    this.albumArtist,
    this.album,
    this.trackNo,
    this.discNo,
    this.durationMs = 0,
    this.year,
    this.genre,
    this.bitrate,
    this.format,
    this.sizeBytes = 0,
    this.fileMtime = 0,
    this.dateAdded,
    this.source = TrackSource.local,
    this.sourceUrl,
    this.mbRecordingId,
    this.mbReleaseId,
    this.mbReleaseGroupId,
    this.mbArtistId,
    this.acoustId,
    this.isrc,
    this.replayGainTrack,
    this.replayGainAlbum,
    this.audioHash,
    this.hasEmbeddedArt = false,
    this.identifyState,
  });

  String filePath;
  String? contentUri;
  String? folder;
  String title;
  String? artist;
  String? albumArtist;
  String? album;
  int? trackNo;
  int? discNo;
  int durationMs;
  int? year;
  String? genre;
  int? bitrate;
  String? format;
  int sizeBytes;
  int fileMtime;
  int? dateAdded;
  TrackSource source;
  String? sourceUrl;
  String? mbRecordingId;
  String? mbReleaseId;
  String? mbReleaseGroupId;
  String? mbArtistId;
  String? acoustId;
  String? isrc;
  double? replayGainTrack;
  double? replayGainAlbum;
  String? audioHash;
  bool hasEmbeddedArt;
  int? identifyState;
}
