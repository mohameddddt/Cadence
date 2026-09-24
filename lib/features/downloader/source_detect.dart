import '../../core/models/track.dart';

/// Result of inspecting a URL pasted or shared into the app.
class SourceInfo {
  const SourceInfo({
    required this.source,
    required this.canonicalUrl,
    this.isPlaylist = false,
    this.id,
    this.supportedByYtDlp = true,
    this.directAudio = false,
  });

  final TrackSource source;

  /// The URL points straight at an audio file (`…/song.mp3`): plain HTTP, no yt-dlp needed.
  final bool directAudio;

  /// Same content -> same string. Used for duplicate detection (tracks.source_url).
  final String canonicalUrl;
  final bool isPlaylist;
  final String? id;
  final bool supportedByYtDlp;

  /// Identifier of the [SourceProvider] that should handle this URL.
  String get providerId => switch (source) {
        TrackSource.internetArchive => 'archive',
        TrackSource.audius => 'audius',
        TrackSource.jamendo => 'jamendo',
        _ when directAudio => 'directfile',
        _ => 'ytdlp',
      };
}

final RegExp _urlPattern = RegExp(r'https?://[^\s<>"“”]+', caseSensitive: false);

/// Pulls the first http(s) URL out of shared text such as
/// "Great song! https://youtu.be/abc?si=xyz" (YouTube/SoundCloud share sheets add prose).
String? extractUrl(String text) {
  final m = _urlPattern.firstMatch(text);
  if (m == null) return null;
  // Trailing punctuation from prose.
  return m.group(0)!.replaceAll(RegExp(r'[)\].,;!?]+$'), '');
}

const Set<String> _trackingParams = {
  'si', 'feature', 'utm_source', 'utm_medium', 'utm_campaign', 'utm_term', 'utm_content', 'fbclid', 'gclid',
  'pp', 'app', 'ab_channel', 'sc_ref', 'context', 'ref', 'ref_',
};

SourceInfo detectSource(String rawUrl) {
  final uri = Uri.tryParse(rawUrl.trim());
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    return SourceInfo(source: TrackSource.other, canonicalUrl: rawUrl.trim(), supportedByYtDlp: false);
  }
  final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^(www|m|mobile)\.'), '');
  final path = uri.path;
  final q = uri.queryParameters;

  String stripQuery(Uri u, {Set<String> keep = const {}, String scheme = 'https'}) {
    final kept = {
      for (final e in u.queryParameters.entries)
        if (keep.contains(e.key) || (!_trackingParams.contains(e.key) && keep.isEmpty)) e.key: e.value,
    };
    return Uri(
      scheme: scheme,
      host: u.host,
      port: u.hasPort ? u.port : null,
      path: u.path,
      queryParameters: kept.isEmpty ? null : kept,
    ).toString();
  }

  // --- YouTube ---------------------------------------------------------------
  if (host == 'youtu.be') {
    final id = path.replaceFirst('/', '').split('/').first;
    return SourceInfo(
      source: TrackSource.youtube,
      canonicalUrl: 'https://www.youtube.com/watch?v=$id',
      id: id,
    );
  }
  if (host == 'youtube.com' || host == 'music.youtube.com' || host == 'youtube-nocookie.com') {
    final isMusic = host == 'music.youtube.com';
    final source = isMusic ? TrackSource.youtubeMusic : TrackSource.youtube;
    final base = isMusic ? 'https://music.youtube.com' : 'https://www.youtube.com';
    final v = q['v'];
    final list = q['list'];
    if (path == '/playlist' || (v == null && list != null) || path.startsWith('/browse')) {
      final id = list ?? path.split('/').last;
      return SourceInfo(
        source: source,
        canonicalUrl: list != null ? '$base/playlist?list=$list' : stripQuery(uri),
        isPlaylist: true,
        id: id,
      );
    }
    if (v != null) {
      return SourceInfo(source: source, canonicalUrl: '$base/watch?v=$v', id: v);
    }
    if (path.startsWith('/shorts/') || path.startsWith('/live/') || path.startsWith('/embed/')) {
      final id = path.split('/').where((s) => s.isNotEmpty).elementAtOrNull(1);
      if (id != null) return SourceInfo(source: source, canonicalUrl: '$base/watch?v=$id', id: id);
    }
    // channels, search pages, etc: let yt-dlp decide, treat as a playlist-like listing
    return SourceInfo(source: source, canonicalUrl: stripQuery(uri), isPlaylist: true);
  }

  // --- SoundCloud ------------------------------------------------------------
  if (host == 'soundcloud.com' || host == 'on.soundcloud.com' || host == 'snd.sc') {
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    final isSet = segments.contains('sets');
    // artist page (1 segment) or /likes, /tracks, /albums listings are collections too
    final isListing = segments.length == 1 || (segments.length == 2 && const {'tracks', 'likes', 'albums', 'reposts', 'sets', 'popular-tracks'}.contains(segments[1]));
    return SourceInfo(
      source: TrackSource.soundcloud,
      canonicalUrl: stripQuery(uri, keep: const {'secret_token'}),
      isPlaylist: isSet || isListing,
      id: segments.join('/'),
    );
  }

  // --- Bandcamp (custom domains exist; *.bandcamp.com covers most) --------------
  if (host.endsWith('bandcamp.com')) {
    final isAlbum = path.startsWith('/album/') || path == '/music' || path == '/' || path.isEmpty;
    return SourceInfo(
      source: TrackSource.bandcamp,
      canonicalUrl: stripQuery(uri),
      isPlaylist: isAlbum,
      id: path,
    );
  }

  // --- Internet Archive --------------------------------------------------------
  if (host == 'archive.org') {
    final segs = path.split('/').where((s) => s.isNotEmpty).toList();
    if (segs.length >= 2 && (segs[0] == 'details' || segs[0] == 'download')) {
      return SourceInfo(
        source: TrackSource.internetArchive,
        canonicalUrl: 'https://archive.org/details/${segs[1]}',
        isPlaylist: segs.length == 2, // a whole item: pick files
        id: segs[1],
        supportedByYtDlp: true,
      );
    }
    return SourceInfo(source: TrackSource.internetArchive, canonicalUrl: stripQuery(uri), supportedByYtDlp: false);
  }

  // --- others yt-dlp handles ---------------------------------------------------
  if (host == 'audius.co') {
    return SourceInfo(source: TrackSource.audius, canonicalUrl: stripQuery(uri), id: path);
  }
  if (host == 'jamendo.com') {
    return SourceInfo(source: TrackSource.jamendo, canonicalUrl: stripQuery(uri), id: path, supportedByYtDlp: false);
  }
  if (host == 'mixcloud.com') {
    return SourceInfo(source: TrackSource.mixcloud, canonicalUrl: stripQuery(uri), id: path);
  }
  if (host == 'vimeo.com' || host == 'player.vimeo.com') {
    return SourceInfo(source: TrackSource.vimeo, canonicalUrl: stripQuery(uri), id: path);
  }
  if (host == 'twitch.tv' || host == 'clips.twitch.tv') {
    return SourceInfo(source: TrackSource.twitch, canonicalUrl: stripQuery(uri), id: path);
  }
  if (host == 'ccmixter.org') {
    return SourceInfo(source: TrackSource.ccmixter, canonicalUrl: stripQuery(uri), id: path, supportedByYtDlp: false);
  }
  // A bare link to an audio file (a blog, a podcast CDN, a NAS…): download it as is. Keep the
  // scheme and the query - both can matter for a plain file URL (http-only hosts, signed links).
  if (_audioFilePath.hasMatch(path)) {
    return SourceInfo(
      source: TrackSource.other,
      canonicalUrl: Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null, path: uri.path, query: uri.hasQuery ? uri.query : null).toString(),
      id: path,
      supportedByYtDlp: false,
      directAudio: true,
    );
  }
  // Anything else: yt-dlp supports ~1000 sites, so give it a go.
  return SourceInfo(source: TrackSource.other, canonicalUrl: stripQuery(uri, scheme: uri.scheme), id: path);
}

final RegExp _audioFilePath = RegExp(r'\.(mp3|m4a|flac|ogg|oga|opus|wav|aac)$', caseSensitive: false);
