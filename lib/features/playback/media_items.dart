import 'package:audio_service/audio_service.dart';

import '../../core/models/track.dart';

/// Keys used in [MediaItem.extras].
class MediaExtras {
  const MediaExtras._();

  static const trackId = 'trackId';
  static const filePath = 'filePath';
  static const source = 'source';
  static const sourceUrl = 'sourceUrl';
  static const rgTrack = 'rgTrack';
  static const rgAlbum = 'rgAlbum';
  static const mbRecordingId = 'mbRecordingId';
  static const albumId = 'albumId';
  static const artistId = 'artistId';
  static const lyricsOffsetMs = 'lyricsOffsetMs';

  /// Remote items: [remote] is true, [resolveUrl] is what yt-dlp resolves to a stream.
  static const remote = 'remote';
  static const resolveUrl = 'resolveUrl';
  static const resolvedAt = 'resolvedAt';
  static const isRadio = 'isRadio';
  static const isPodcast = 'isPodcast';
  static const thumbnail = 'thumbnail';
}

/// Track -> queue item. The id is the URI the player opens.
MediaItem trackToMediaItem(Track t, {Uri? art}) => MediaItem(
      id: t.playUri.toString(),
      title: t.title,
      artist: t.displayArtist,
      album: t.albumTitle,
      genre: t.genre,
      duration: t.durationMs > 0 ? Duration(milliseconds: t.durationMs) : null,
      artUri: art,
      extras: {
        MediaExtras.trackId: t.id,
        MediaExtras.filePath: t.filePath,
        MediaExtras.source: t.source.name,
        if (t.sourceUrl != null) MediaExtras.sourceUrl: t.sourceUrl,
        if (t.replayGainTrack != null) MediaExtras.rgTrack: t.replayGainTrack,
        if (t.replayGainAlbum != null) MediaExtras.rgAlbum: t.replayGainAlbum,
        if (t.mbRecordingId != null) MediaExtras.mbRecordingId: t.mbRecordingId,
        if (t.albumId != null) MediaExtras.albumId: t.albumId,
        if (t.artistId != null) MediaExtras.artistId: t.artistId,
        MediaExtras.lyricsOffsetMs: t.lyricsOffsetMs,
      },
    );

extension MediaItemX on MediaItem {
  int? get trackId => (extras?[MediaExtras.trackId] as num?)?.toInt();
  bool get isRemote => extras?[MediaExtras.remote] == true;
  bool get isRadio => extras?[MediaExtras.isRadio] == true;
  String? get resolveUrl => extras?[MediaExtras.resolveUrl] as String?;
  String? get sourceUrl => extras?[MediaExtras.sourceUrl] as String?;
  double? get rgTrack => (extras?[MediaExtras.rgTrack] as num?)?.toDouble();
  double? get rgAlbum => (extras?[MediaExtras.rgAlbum] as num?)?.toDouble();
  int get lyricsOffsetMs => (extras?[MediaExtras.lyricsOffsetMs] as num?)?.toInt() ?? 0;
  int? get albumId => (extras?[MediaExtras.albumId] as num?)?.toInt();
  int? get artistId => (extras?[MediaExtras.artistId] as num?)?.toInt();

  /// A stable key for play statistics (tracks: db id, remote: the source URL).
  String get playKey => trackId != null ? 'track:$trackId' : 'url:${sourceUrl ?? resolveUrl ?? id}';
}

Map<String, Object?> mediaItemToJson(MediaItem m) => {
      'id': m.id,
      'title': m.title,
      'album': m.album,
      'artist': m.artist,
      'genre': m.genre,
      'durationMs': m.duration?.inMilliseconds,
      'artUri': m.artUri?.toString(),
      'extras': m.extras,
    };

MediaItem mediaItemFromJson(Map<String, Object?> j) => MediaItem(
      id: j['id'] as String,
      title: (j['title'] as String?) ?? '',
      album: j['album'] as String?,
      artist: j['artist'] as String?,
      genre: j['genre'] as String?,
      duration: j['durationMs'] == null ? null : Duration(milliseconds: (j['durationMs'] as num).toInt()),
      artUri: j['artUri'] == null ? null : Uri.parse(j['artUri'] as String),
      extras: (j['extras'] as Map?)?.cast<String, dynamic>(),
    );
