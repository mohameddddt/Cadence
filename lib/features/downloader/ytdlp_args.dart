import '../../core/models/track.dart';
import '../../core/settings/settings_store.dart';
import 'download_models.dart';

/// Builds yt-dlp command lines (plan 3.4). Pure functions so they can be unit tested and
/// mirrored one-to-one by the companion server.
class YtDlpArgs {
  const YtDlpArgs._();

  static const Set<String> audioExtensions = {'m4a', 'mp3', 'opus', 'ogg', 'oga', 'flac', 'wav', 'aac', 'webm', 'mka', 'wma', 'mp4', 'weba'};

  /// Arguments for downloading [url] into [workDir], one file named after the video id.
  static List<String> download(
    String url, {
    required String workDir,
    required DownloadOptions options,
    TrackSource? source,
    String outputTemplate = '%(id)s.%(ext)s',
  }) {
    final a = <String>[
      '--no-playlist',
      '-f', 'bestaudio/best',
      '-x',
      ..._audioFormat(options),
      '--embed-metadata',
      if (options.embedThumbnail) ...['--embed-thumbnail', '--convert-thumbnails', 'jpg'],
      // "Artist - Title" video titles become artist + title tags (no effect when the title has no dash).
      if (options.parseTitle) ...['--parse-metadata', 'title:%(artist)s - %(title)s'],
      '--write-info-json',
      '--no-mtime',
      '--newline',
      '--progress',
      '--retries', '5',
      '--fragment-retries', '5',
      '--concurrent-fragments', '4',
      if (options.limitRate != null && options.limitRate!.isNotEmpty) ...['--limit-rate', options.limitRate!],
      if (options.sponsorBlock && _isYouTube(source)) ...['--sponsorblock-remove', 'music_offtopic'],
      if (options.cookiesFile != null && options.cookiesFile!.isNotEmpty) ...['--cookies', options.cookiesFile!],
      if (options.useAria2) ...['--downloader', 'aria2c'],
      ...options.extraArgs,
      '-P', workDir,
      '-o', outputTemplate,
      url,
    ];
    return a;
  }

  static bool _isYouTube(TrackSource? s) => s == TrackSource.youtube || s == TrackSource.youtubeMusic;

  static List<String> _audioFormat(DownloadOptions o) {
    switch (o.format) {
      case AudioFormatChoice.original:
        return const []; // yt-dlp keeps the native stream (Opus/M4A): no quality loss
      case AudioFormatChoice.m4a:
        return ['--audio-format', 'm4a', '--audio-quality', '${o.quality}'];
      case AudioFormatChoice.opus:
        return ['--audio-format', 'opus', '--audio-quality', '${o.quality}'];
      case AudioFormatChoice.mp3:
        return ['--audio-format', 'mp3', '--audio-quality', '${o.quality}'];
      case AudioFormatChoice.flac:
        return const ['--audio-format', 'flac'];
    }
  }

  /// One JSON document describing a single item (no download).
  static List<String> info(String url, {String? cookiesFile}) => [
        '-J',
        '--no-playlist',
        '--no-warnings',
        '--skip-download',
        if (cookiesFile != null && cookiesFile.isNotEmpty) ...['--cookies', cookiesFile],
        url,
      ];

  /// List the entries of a playlist/album/channel without resolving each one.
  static List<String> flatPlaylist(String url, {String? cookiesFile}) => [
        '-J',
        '--flat-playlist',
        '--no-warnings',
        if (cookiesFile != null && cookiesFile.isNotEmpty) ...['--cookies', cookiesFile],
        url,
      ];

  /// `ytsearch10:query` style search (results are flat entries).
  static List<String> search(String prefix, String query, int count, {String? cookiesFile}) => [
        '-J',
        '--flat-playlist',
        '--no-warnings',
        if (cookiesFile != null && cookiesFile.isNotEmpty) ...['--cookies', cookiesFile],
        '$prefix$count:$query',
      ];

  /// Direct stream URL (expires: YouTube ~6 h, so resolve again on 403).
  static List<String> streamUrl(String url, {String? cookiesFile}) => [
        '-f', 'bestaudio/best',
        '-g',
        '--no-playlist',
        '--no-warnings',
        if (cookiesFile != null && cookiesFile.isNotEmpty) ...['--cookies', cookiesFile],
        url,
      ];

  /// yt-dlp search prefixes per source (Bandcamp has no search).
  static String? searchPrefix(TrackSource s) => switch (s) {
        TrackSource.youtube => 'ytsearch',
        TrackSource.soundcloud => 'scsearch',
        TrackSource.youtubeMusic => 'ytsearch',
        _ => null,
      };

  /// Progress lines: "[download]  42.3% of ~ 4.20MiB at  1.2MiB/s ETA 00:03".
  static double? parsePercent(String line) {
    final m = RegExp(r'\[download\]\s+(\d+(?:\.\d+)?)%').firstMatch(line);
    return m == null ? null : double.tryParse(m.group(1)!);
  }

  /// Names the postprocessing stage from an output line, for the UI.
  static String? stageOf(String line) {
    if (line.contains('[ExtractAudio]')) return 'Converting audio';
    if (line.contains('[Metadata]') || line.contains('[EmbedThumbnail]')) return 'Embedding metadata';
    if (line.contains('[SponsorBlock]') || line.contains('[ModifyChapters]')) return 'Removing non-music parts';
    if (line.contains('[ThumbnailsConvertor]')) return 'Preparing cover';
    if (line.contains('[download]') && line.contains('Destination')) return 'Downloading';
    return null;
  }
}
