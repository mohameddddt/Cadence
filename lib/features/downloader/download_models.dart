import '../../core/models/track.dart';
import '../../core/settings/settings_store.dart';
import 'source_detect.dart';

/// Everything the downloader needs to know that does not come from the URL.
class DownloadOptions {
  const DownloadOptions({
    this.format = AudioFormatChoice.m4a,
    this.quality = 0,
    this.sponsorBlock = true,
    this.parseTitle = true,
    this.embedThumbnail = false,
    this.cookiesFile,
    this.extraArgs = const [],
    this.limitRate,
    this.useAria2 = false,
  });

  final AudioFormatChoice format;

  /// yt-dlp --audio-quality (0 best .. 10 worst); only used when converting.
  final int quality;
  final bool sponsorBlock;

  /// Split "Artist - Title" video titles into artist + title tags.
  final bool parseTitle;

  /// Let yt-dlp embed the thumbnail with ffmpeg. Off by default: the bundled ffmpeg is minimal and
  /// fails on some formats, and the app crops + embeds covers itself (square, <= 1200 px).
  final bool embedThumbnail;
  final String? cookiesFile;
  final List<String> extraArgs;
  final String? limitRate;
  final bool useAria2;

  factory DownloadOptions.fromSettings(SettingsStore s) => DownloadOptions(
        format: s.downloadFormat,
        quality: s.downloadQuality,
        sponsorBlock: s.sponsorBlock,
        cookiesFile: s.cookiesFile,
        extraArgs: s.extraYtDlpArgs.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
      );

  Map<String, dynamic> toJson() => {
        'format': format.name,
        'quality': quality,
        'sponsorBlock': sponsorBlock,
        'parseTitle': parseTitle,
        'embedThumbnail': embedThumbnail,
        'extraArgs': extraArgs,
        if (limitRate != null) 'limitRate': limitRate,
      };

  factory DownloadOptions.fromJson(Map<String, dynamic> j) => DownloadOptions(
        format: AudioFormatChoice.values.firstWhere((e) => e.name == j['format'], orElse: () => AudioFormatChoice.m4a),
        quality: (j['quality'] as num?)?.toInt() ?? 0,
        sponsorBlock: (j['sponsorBlock'] as bool?) ?? true,
        parseTitle: (j['parseTitle'] as bool?) ?? true,
        embedThumbnail: (j['embedThumbnail'] as bool?) ?? false,
        extraArgs: [for (final a in (j['extraArgs'] as List?) ?? const []) a.toString()],
        limitRate: j['limitRate'] as String?,
      );
}

/// What yt-dlp (or a direct provider) knows about one item before downloading it.
class MediaInfo {
  const MediaInfo({
    required this.url,
    required this.title,
    this.id,
    this.uploader,
    this.artist,
    this.album,
    this.track,
    this.durationSec,
    this.thumbnail,
    this.releaseYear,
    this.license,
    this.extractor,
    this.isPlaylist = false,
    this.entries = const [],
    this.description,
    this.trackNumber,
  });

  final String url;
  final String title;
  final String? id;
  final String? uploader;
  final String? artist;
  final String? album;
  final String? track;
  final int? durationSec;
  final String? thumbnail;
  final int? releaseYear;
  final String? license;
  final String? extractor;
  final bool isPlaylist;
  final List<MediaInfo> entries;
  final String? description;
  final int? trackNumber;

  /// Best guess of the artist without any title parsing.
  String? get bestArtist => artist ?? uploader;

  TrackSource get source => detectSource(url).source;

  factory MediaInfo.fromJson(Map<String, dynamic> j, {String? fallbackUrl}) {
    String? s(String k) {
      final v = j[k];
      if (v == null) return null;
      final t = v.toString().trim();
      return t.isEmpty ? null : t;
    }

    final url = s('webpage_url') ?? s('original_url') ?? s('url') ?? fallbackUrl ?? '';
    String? artist = s('artist');
    final artists = j['artists'];
    if (artist == null && artists is List && artists.isNotEmpty) artist = artists.map((e) => e.toString()).join(', ');
    artist ??= s('creator');
    int? year = (j['release_year'] as num?)?.toInt();
    year ??= int.tryParse((s('release_date') ?? s('upload_date') ?? '').padRight(4).substring(0, 4).trim());

    String? thumb = s('thumbnail');
    if (thumb == null && j['thumbnails'] is List && (j['thumbnails'] as List).isNotEmpty) {
      thumb = ((j['thumbnails'] as List).last as Map)['url'] as String?;
    }
    final entriesRaw = j['entries'];
    final isPlaylist = j['_type'] == 'playlist' || entriesRaw is List;
    return MediaInfo(
      url: url,
      id: s('id'),
      title: s('title') ?? s('fulltitle') ?? 'Untitled',
      uploader: s('uploader') ?? s('channel') ?? s('uploader_id'),
      artist: artist,
      album: s('album'),
      track: s('track'),
      durationSec: (j['duration'] as num?)?.round(),
      thumbnail: thumb,
      releaseYear: year,
      license: s('license'),
      extractor: s('extractor_key') ?? s('ie_key') ?? s('extractor'),
      isPlaylist: isPlaylist,
      description: s('description'),
      trackNumber: (j['track_number'] as num?)?.toInt() ?? (j['playlist_index'] as num?)?.toInt(),
      entries: isPlaylist
          ? [
              for (final e in (entriesRaw as List? ?? const []))
                if (e is Map) MediaInfo.fromJson(e.cast<String, dynamic>(), fallbackUrl: null),
            ]
          : const [],
    );
  }
}

enum DownloadErrorKind {
  signInRequired,
  ageRestricted,
  unavailable,
  geoBlocked,
  drmProtected,
  network,
  forbidden,
  rateLimited,
  needsUpdate,
  noSpace,
  ffmpeg,
  cancelled,
  unknown,
}

/// A yt-dlp failure translated into something a person can act on.
class DownloadError {
  const DownloadError(this.kind, this.message, {this.hint, this.retryable = false});

  final DownloadErrorKind kind;
  final String message;
  final String? hint;
  final bool retryable;

  /// Maps yt-dlp's stderr/exception text onto a [DownloadErrorKind].
  static DownloadError classify(String raw) {
    final t = raw.toLowerCase();
    bool has(String s) => t.contains(s);
    if (has('age-restricted') || has('confirm your age') || has('age verification') || has('inappropriate for some users')) {
      return const DownloadError(DownloadErrorKind.ageRestricted, 'Age-restricted content.',
          hint: 'Add a cookies file from a signed-in browser in Settings > Downloads.');
    }
    if (has('not a bot') || has('sign in to confirm you')) {
      return const DownloadError(DownloadErrorKind.signInRequired, 'YouTube wants you to sign in (bot check).',
          hint: 'Set a cookies file in Settings > Downloads, or update yt-dlp.', retryable: true);
    }
    if (has('drm') || has('go+') || has('this track is not available for download')) {
      return const DownloadError(DownloadErrorKind.drmProtected, 'This track is protected or stream-only.',
          hint: 'SoundCloud Go+ tracks and DRM streams cannot be downloaded.');
    }
    if (has('in your country') || has('geo') && has('restrict')) {
      return const DownloadError(DownloadErrorKind.geoBlocked, 'Not available in your country.');
    }
    if (has('video unavailable') || has('private video') || has('video is private') || has('is private') || has('has been removed') || has('this video is not available') || has('404') && has('not found')) {
      return const DownloadError(DownloadErrorKind.unavailable, 'The video or track is no longer available.');
    }
    if (has('http error 403') || has('403: forbidden')) {
      return const DownloadError(DownloadErrorKind.forbidden, 'The site refused the download (HTTP 403).',
          hint: 'Update yt-dlp - the site probably changed.', retryable: true);
    }
    if (has('http error 429') || has('too many requests')) {
      return const DownloadError(DownloadErrorKind.rateLimited, 'Rate limited by the site.', hint: 'Try again in a few minutes.', retryable: true);
    }
    if (has('unable to extract') || has('unsupported url') || has('please report this issue') || has('nsig') || has('signature extraction')) {
      return const DownloadError(DownloadErrorKind.needsUpdate, 'yt-dlp cannot read this page (site changed).',
          hint: 'Use "Update yt-dlp" in Settings > Downloads.', retryable: true);
    }
    if (has('ffmpeg') && (has('not found') || has('not installed') || has('postprocessing'))) {
      return const DownloadError(DownloadErrorKind.ffmpeg, 'Audio conversion failed (ffmpeg).', hint: 'Choose "Original" format or update the app.');
    }
    if (has('no space left') || has('enospc')) {
      return const DownloadError(DownloadErrorKind.noSpace, 'The device is out of storage space.');
    }
    if (has('timed out') || has('connection reset') || has('network is unreachable') || has('name or service not known') ||
        has('unable to download webpage') || has('temporary failure in name resolution') || has('read timeout') || has('urlopen error') ||
        has('socketexception') || has('connection closed') || has('connection error') || has('connection refused') || has('failed host lookup')) {
      return const DownloadError(DownloadErrorKind.network, 'Network problem.', hint: 'Check your connection and retry.', retryable: true);
    }
    if (has('cancel')) return const DownloadError(DownloadErrorKind.cancelled, 'Cancelled.');
    // Keep the last meaningful line so the user sees something concrete.
    final lines = raw.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    final err = lines.lastWhere((l) => l.toUpperCase().startsWith('ERROR'), orElse: () => lines.isEmpty ? 'Download failed' : lines.last);
    return DownloadError(DownloadErrorKind.unknown, err.length > 300 ? '${err.substring(0, 300)}…' : err, retryable: true);
  }
}
