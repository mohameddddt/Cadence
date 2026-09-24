import 'package:audio_service/audio_service.dart';

import '../../core/models/track.dart';
import '../downloader/source_detect.dart';
import '../playback/media_items.dart';

/// One search result / playable / downloadable thing from a remote source.
class RemoteTrack {
  const RemoteTrack({
    required this.id,
    required this.provider,
    required this.source,
    required this.title,
    required this.pageUrl,
    this.artist,
    this.album,
    this.durationSec,
    this.thumbnail,
    this.streamUrl,
    this.downloadUrl,
    this.isCollection = false,
    this.license,
    this.format,
    this.sizeBytes,
    this.trackNumber,
    this.year,
    this.extra = const {},
  });

  final String id;

  /// [SourceProvider.id] that produced it.
  final String provider;
  final TrackSource source;
  final String title;
  final String? artist;
  final String? album;
  final int? durationSec;
  final String? thumbnail;

  /// The page (or canonical URL) - also what identifies duplicates.
  final String pageUrl;

  /// Directly playable URL if the provider knows one; otherwise resolved through yt-dlp.
  final String? streamUrl;

  /// Directly downloadable file (no yt-dlp needed).
  final String? downloadUrl;

  /// An album / playlist / archive item that expands to several tracks.
  final bool isCollection;
  final String? license;
  final String? format;
  final int? sizeBytes;
  final int? trackNumber;
  final int? year;
  final Map<String, Object?> extra;

  bool get isDirect => downloadUrl != null;

  Duration? get duration => durationSec == null ? null : Duration(seconds: durationSec!);

  /// Queue item for streaming without downloading.
  MediaItem toMediaItem() => MediaItem(
        id: streamUrl ?? pageUrl,
        title: title,
        artist: artist,
        album: album,
        duration: duration,
        artUri: thumbnail == null ? null : Uri.tryParse(thumbnail!),
        extras: {
          MediaExtras.remote: true,
          MediaExtras.source: source.name,
          MediaExtras.sourceUrl: pageUrl,
          if (streamUrl == null) MediaExtras.resolveUrl: pageUrl,
          if (thumbnail != null) MediaExtras.thumbnail: thumbnail,
        },
      );

  String get canonicalUrl => detectSource(pageUrl).canonicalUrl;
}

/// A place audio can be found (plan 7.1): implement [search], [expand] and either a
/// direct URL or yt-dlp resolution. Each provider can be switched off in Settings.
abstract class SourceProvider {
  String get id;
  String get label;
  TrackSource get source;

  /// Extra explanation shown in the UI (legal notes, e.g. Bandcamp / SoundCloud).
  String? get note => null;

  bool get supportsSearch => true;

  bool canHandle(SourceInfo info) => info.source == source;

  Future<List<RemoteTrack>> search(String query, {int limit = 15});

  /// Members of an album / playlist / archive item.
  Future<List<RemoteTrack>> expand(RemoteTrack collection) async => const [];

  /// Metadata for a pasted URL, or null when this provider cannot resolve it directly.
  Future<RemoteTrack?> resolve(String url) async => null;
}
