import '../../core/models/track.dart';
import '../downloader/download_models.dart';
import '../downloader/engines.dart';
import '../downloader/source_detect.dart';
import '../downloader/ytdlp_args.dart';
import 'source_provider.dart';

/// Sites handled by yt-dlp: YouTube, YouTube Music, SoundCloud, Bandcamp, Mixcloud, Vimeo,
/// Twitch and anything else yt-dlp knows (~1000 sites).
class YtDlpSource extends SourceProvider {
  YtDlpSource(this._engine, {required this.id, required this.label, required this.source, this.note, this.searchUrlBuilder});

  final DownloadEngine Function() _engine;

  @override
  final String id;
  @override
  final String label;
  @override
  final TrackSource source;
  @override
  final String? note;

  /// For sites whose search is a page URL rather than a `xxsearch:` prefix (YouTube Music).
  final String Function(String query)? searchUrlBuilder;

  @override
  bool get supportsSearch => YtDlpArgs.searchPrefix(source) != null || searchUrlBuilder != null;

  @override
  bool canHandle(SourceInfo info) => info.supportedByYtDlp && (info.source == source || (source == TrackSource.other && info.source == TrackSource.other));

  @override
  Future<List<RemoteTrack>> search(String query, {int limit = 15}) async {
    if (!supportsSearch) return const [];
    final List<MediaInfo> entries;
    if (searchUrlBuilder != null) {
      entries = (await _engine().listPlaylist(searchUrlBuilder!(query))).entries.take(limit).toList();
    } else {
      entries = await _engine().search(source, query, count: limit);
    }
    return [for (final e in entries) _toRemote(e)];
  }

  @override
  Future<List<RemoteTrack>> expand(RemoteTrack collection) async {
    final list = await _engine().listPlaylist(collection.pageUrl);
    var n = 0;
    return [
      for (final e in list.entries)
        _toRemote(e, fallbackAlbum: list.title, index: ++n),
    ];
  }

  @override
  Future<RemoteTrack?> resolve(String url) async {
    final info = detectSource(url);
    if (info.isPlaylist) {
      final list = await _engine().listPlaylist(info.canonicalUrl);
      return RemoteTrack(
        id: info.id ?? url,
        provider: id,
        source: info.source,
        title: list.title,
        artist: list.uploader,
        thumbnail: list.thumbnail,
        pageUrl: info.canonicalUrl,
        isCollection: true,
      );
    }
    return _toRemote(await _engine().info(info.canonicalUrl));
  }

  RemoteTrack _toRemote(MediaInfo e, {String? fallbackAlbum, int? index}) {
    final url = e.url.isEmpty ? '' : detectSource(e.url).canonicalUrl;
    final src = detectSource(e.url).source;
    return RemoteTrack(
      id: e.id ?? url,
      provider: id,
      source: src == TrackSource.other ? source : src,
      title: e.track ?? e.title,
      artist: e.artist ?? e.uploader,
      album: e.album ?? fallbackAlbum,
      durationSec: e.durationSec,
      thumbnail: e.thumbnail,
      pageUrl: url,
      isCollection: e.isPlaylist,
      trackNumber: e.trackNumber ?? index,
      year: e.releaseYear,
      license: e.license,
    );
  }
}

/// The yt-dlp backed providers in the order shown in the search UI.
List<SourceProvider> ytDlpProviders(DownloadEngine Function() engine) => [
      YtDlpSource(engine, id: 'youtube', label: 'YouTube', source: TrackSource.youtube,
          note: 'Downloading from YouTube breaks its terms of service - personal use only.'),
      YtDlpSource(engine, id: 'youtubemusic', label: 'YouTube Music', source: TrackSource.youtubeMusic,
          searchUrlBuilder: (q) => 'https://music.youtube.com/search?q=${Uri.encodeQueryComponent(q)}',
          note: 'Cleaner artist/album metadata than plain YouTube.'),
      YtDlpSource(engine, id: 'soundcloud', label: 'SoundCloud', source: TrackSource.soundcloud,
          note: 'Many tracks are stream-only; Go+ tracks (DRM) cannot be downloaded.'),
      YtDlpSource(engine, id: 'bandcamp', label: 'Bandcamp', source: TrackSource.bandcamp,
          note: 'Paste album/track links. Only 128 kbps streams unless you bought the release.'),
      YtDlpSource(engine, id: 'mixcloud', label: 'Mixcloud', source: TrackSource.mixcloud),
      YtDlpSource(engine, id: 'vimeo', label: 'Vimeo', source: TrackSource.vimeo),
      YtDlpSource(engine, id: 'twitch', label: 'Twitch', source: TrackSource.twitch),
      YtDlpSource(engine, id: 'ytdlp-other', label: 'Other sites (yt-dlp)', source: TrackSource.other),
    ];
