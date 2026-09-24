import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import '../../core/models/track.dart';
import '../../core/net/http_service.dart';
import '../../core/settings/settings_store.dart';
import '../../platform/bridges.dart';
import 'download_models.dart';
import 'ytdlp_args.dart';

/// A failed engine call with a human-friendly explanation.
class DownloadFailure implements Exception {
  DownloadFailure(this.error, [this.raw = '']);

  final DownloadError error;
  final String raw;

  bool get cancelled => error.kind == DownloadErrorKind.cancelled;

  @override
  String toString() => 'DownloadFailure(${error.kind.name}: ${error.message})';
}

class EngineResult {
  const EngineResult({required this.files, this.info, this.log = ''});

  /// Audio files produced (usually one).
  final List<File> files;

  /// yt-dlp's `.info.json` (or provider metadata) if available.
  final Map<String, dynamic>? info;
  final String log;
}

typedef ProgressCallback = void Function(double percent, String? stage);

/// Something that can list, search, resolve and download media.
abstract class DownloadEngine {
  String get id;
  String get label;

  Future<void> ensureReady();
  Future<String?> version();
  Future<String> update(String channel);

  /// Metadata of one item (no download).
  Future<MediaInfo> info(String url);

  /// Entries of a playlist / album / channel (flat, cheap).
  Future<MediaInfo> listPlaylist(String url);

  /// Search on [source] (`ytsearch`, `scsearch`). Empty for sources without search.
  Future<List<MediaInfo>> search(TrackSource source, String query, {int count = 10});

  /// Direct, short-lived stream URL for playback.
  Future<Uri> streamUrl(String url);

  Future<EngineResult> download({
    required String jobId,
    required String url,
    required TrackSource source,
    required Directory workDir,
    required DownloadOptions options,
    ProgressCallback? onProgress,
  });

  Future<void> cancel(String jobId);
}

/// Picks audio files out of a finished job directory and reads yt-dlp's info json.
class WorkDirReader {
  const WorkDirReader._();

  static EngineResult read(Directory dir, {String log = ''}) {
    final files = <File>[];
    Map<String, dynamic>? info;
    if (dir.existsSync()) {
      for (final e in dir.listSync().whereType<File>()) {
        final name = e.path.split(RegExp(r'[\\/]')).last.toLowerCase();
        if (name.endsWith('.info.json')) {
          try {
            info ??= (jsonDecode(e.readAsStringSync()) as Map).cast<String, dynamic>();
          } on FormatException {
            // ignore a truncated file
          }
          continue;
        }
        final ext = name.contains('.') ? name.substring(name.lastIndexOf('.') + 1) : '';
        if (YtDlpArgs.audioExtensions.contains(ext) && !name.endsWith('.part')) files.add(e);
      }
    }
    // Biggest first: partial/sidecar files (webm video fragments) are smaller than the final audio.
    files.sort((a, b) => b.lengthSync().compareTo(a.lengthSync()));
    return EngineResult(files: files, info: info, log: log);
  }
}

// ---------------------------------------------------------------------------
// On-device yt-dlp (Android, youtubedl-android)
// ---------------------------------------------------------------------------

class LocalYtDlpEngine implements DownloadEngine {
  LocalYtDlpEngine(this.bridge, this.settings);

  final YtDlpBridge bridge;
  final SettingsStore settings;
  Future<void>? _ready;

  @override
  String get id => 'local';

  @override
  String get label => 'On-device yt-dlp';

  @override
  Future<void> ensureReady() => _ready ??= bridge.init().then((_) {}).catchError((Object e) {
        _ready = null;
        throw DownloadFailure(DownloadError.classify(e.toString()), e.toString());
      });

  @override
  Future<String?> version() async {
    await ensureReady();
    return bridge.version();
  }

  @override
  Future<String> update(String channel) async {
    await ensureReady();
    final r = await bridge.update(channel);
    return '${r.status} (${r.version})';
  }

  Future<Map<String, dynamic>> _json(List<String> args) async {
    await ensureReady();
    try {
      final r = await bridge.run(args);
      if (r.exitCode != 0 && r.out.trim().isEmpty) throw DownloadFailure(DownloadError.classify(r.err), r.err);
      return (jsonDecode(r.out.trim().split('\n').last) as Map).cast<String, dynamic>();
    } on PlatformFailure catch (e) {
      throw DownloadFailure(DownloadError.classify(e.message), e.message);
    } on FormatException catch (e) {
      throw DownloadFailure(DownloadError.classify('unexpected yt-dlp output: ${e.message}'));
    }
  }

  @override
  Future<MediaInfo> info(String url) async => MediaInfo.fromJson(await _json(YtDlpArgs.info(url, cookiesFile: settings.cookiesFile)), fallbackUrl: url);

  @override
  Future<MediaInfo> listPlaylist(String url) async =>
      MediaInfo.fromJson(await _json(YtDlpArgs.flatPlaylist(url, cookiesFile: settings.cookiesFile)), fallbackUrl: url);

  @override
  Future<List<MediaInfo>> search(TrackSource source, String query, {int count = 10}) async {
    final prefix = YtDlpArgs.searchPrefix(source);
    if (prefix == null) return const [];
    final j = await _json(YtDlpArgs.search(prefix, query, count, cookiesFile: settings.cookiesFile));
    final list = MediaInfo.fromJson(j);
    return [
      for (final e in list.entries)
        if (e.url.isNotEmpty) e,
    ];
  }

  @override
  Future<Uri> streamUrl(String url) async {
    await ensureReady();
    try {
      final r = await bridge.run(YtDlpArgs.streamUrl(url, cookiesFile: settings.cookiesFile));
      final line = r.out.split('\n').map((l) => l.trim()).firstWhere((l) => l.startsWith('http'), orElse: () => '');
      if (line.isEmpty) throw DownloadFailure(DownloadError.classify(r.err), r.err);
      return Uri.parse(line);
    } on PlatformFailure catch (e) {
      throw DownloadFailure(DownloadError.classify(e.message), e.message);
    }
  }

  @override
  Future<EngineResult> download({
    required String jobId,
    required String url,
    required TrackSource source,
    required Directory workDir,
    required DownloadOptions options,
    ProgressCallback? onProgress,
  }) async {
    await ensureReady();
    workDir.createSync(recursive: true);
    final args = YtDlpArgs.download(url, workDir: workDir.path, options: options, source: source);
    final log = StringBuffer();
    final sub = bridge.progress.where((p) => p.jobId == jobId).listen((p) {
      final stage = YtDlpArgs.stageOf(p.line);
      onProgress?.call(p.percent < 0 ? 0 : p.percent, stage);
      if (p.line.isNotEmpty) log.writeln(p.line);
    });
    try {
      final r = await bridge.download(jobId, args);
      log.writeln(r.err);
      if (r.exitCode != 0) throw DownloadFailure(DownloadError.classify('${r.err}\n${r.out}'), r.err);
    } on PlatformFailure catch (e) {
      if (e.cancelled) throw DownloadFailure(const DownloadError(DownloadErrorKind.cancelled, 'Cancelled.'));
      throw DownloadFailure(DownloadError.classify(e.message), e.message);
    } finally {
      await sub.cancel();
    }
    final result = WorkDirReader.read(workDir, log: log.toString());
    if (result.files.isEmpty) {
      throw DownloadFailure(const DownloadError(DownloadErrorKind.unknown, 'yt-dlp finished but produced no audio file.', retryable: true), log.toString());
    }
    return result;
  }

  @override
  Future<void> cancel(String jobId) async {
    try {
      await bridge.cancel(jobId);
    } on PlatformFailure {
      // nothing running
    }
  }
}

// ---------------------------------------------------------------------------
// Companion server (iOS, or Android without the on-device engine)
// ---------------------------------------------------------------------------

/// Talks to the FastAPI server in /server. See server/README.md for the protocol.
class ServerYtDlpEngine implements DownloadEngine {
  ServerYtDlpEngine(this.http, {required this.baseUrl, required this.token, this.pollInterval = const Duration(seconds: 1)});

  final HttpService http;
  final String Function() baseUrl;
  final String Function() token;
  final Duration pollInterval;
  final Map<String, String> _remoteJobs = {};
  final Set<String> _cancelled = {};

  @override
  String get id => 'server';

  @override
  String get label => 'Companion server';

  Map<String, String> get _auth => {if (token().isNotEmpty) 'Authorization': 'Bearer ${token()}'};

  String get _base {
    final b = baseUrl().trim().replaceAll(RegExp(r'/+$'), '');
    if (b.isEmpty) throw DownloadFailure(const DownloadError(DownloadErrorKind.network, 'No server URL configured.', hint: 'Set it in Settings > Downloads.'));
    return b;
  }

  Future<T> _wrap<T>(Future<T> Function() f) async {
    try {
      return await f();
    } on HttpFailure catch (e) {
      final code = e.statusCode;
      if (code == 401 || code == 403) {
        throw DownloadFailure(const DownloadError(DownloadErrorKind.forbidden, 'The server rejected the access token.', hint: 'Check the token in Settings > Downloads.'));
      }
      throw DownloadFailure(DownloadError.classify(e.message), e.message);
    }
  }

  @override
  Future<void> ensureReady() async {
    await _wrap(() => http.getJson('$_base/health', headers: _auth));
  }

  @override
  Future<String?> version() async {
    final j = await _wrap(() => http.getJson('$_base/health', headers: _auth));
    return (j as Map)['yt_dlp'] as String?;
  }

  @override
  Future<String> update(String channel) async {
    final j = await _wrap(() => http.postJson('$_base/update', body: {'channel': channel}, headers: _auth));
    final m = (j as Map?) ?? const {};
    return '${m['status'] ?? 'DONE'} (${m['version'] ?? ''})';
  }

  @override
  Future<MediaInfo> info(String url) async {
    final j = await _wrap(() => http.getJson('$_base/info', query: {'url': url}, headers: _auth));
    return MediaInfo.fromJson((j as Map).cast<String, dynamic>(), fallbackUrl: url);
  }

  @override
  Future<MediaInfo> listPlaylist(String url) async {
    final j = await _wrap(() => http.getJson('$_base/playlist', query: {'url': url}, headers: _auth));
    return MediaInfo.fromJson((j as Map).cast<String, dynamic>(), fallbackUrl: url);
  }

  @override
  Future<List<MediaInfo>> search(TrackSource source, String query, {int count = 10}) async {
    if (YtDlpArgs.searchPrefix(source) == null) return const [];
    final j = await _wrap(() => http.getJson('$_base/search', query: {'q': query, 'source': source.name, 'count': count}, headers: _auth));
    return [
      for (final e in ((j as Map)['entries'] as List? ?? const []))
        MediaInfo.fromJson((e as Map).cast<String, dynamic>()),
    ];
  }

  @override
  Future<Uri> streamUrl(String url) async {
    final j = await _wrap(() => http.getJson('$_base/stream', query: {'url': url}, headers: _auth));
    return Uri.parse((j as Map)['url'] as String);
  }

  @override
  Future<EngineResult> download({
    required String jobId,
    required String url,
    required TrackSource source,
    required Directory workDir,
    required DownloadOptions options,
    ProgressCallback? onProgress,
  }) async {
    workDir.createSync(recursive: true);
    final created = await _wrap(() => http.postJson('$_base/jobs', body: {'url': url, 'source': source.name, 'options': options.toJson()}, headers: _auth));
    final remoteId = (created as Map)['id'] as String;
    _remoteJobs[jobId] = remoteId;
    try {
      // 1. wait for the server to finish
      Map<dynamic, dynamic> status;
      while (true) {
        if (_cancelled.remove(jobId)) {
          throw DownloadFailure(const DownloadError(DownloadErrorKind.cancelled, 'Cancelled.'));
        }
        status = (await _wrap(() => http.getJson('$_base/jobs/$remoteId', headers: _auth))) as Map;
        final st = status['status'] as String?;
        onProgress?.call(((status['progress'] as num?)?.toDouble() ?? 0), status['stage'] as String?);
        if (st == 'done') break;
        if (st == 'failed' || st == 'cancelled') {
          final err = (status['error'] as String?) ?? 'Download failed on the server';
          throw DownloadFailure(st == 'cancelled' ? const DownloadError(DownloadErrorKind.cancelled, 'Cancelled.') : DownloadError.classify(err), err);
        }
        await Future<void>.delayed(pollInterval);
      }
      // 2. fetch the finished files
      final files = <File>[];
      for (final f in (status['files'] as List? ?? const [])) {
        final name = (f as Map)['name'] as String;
        final dest = File('${workDir.path}/$name');
        onProgress?.call(100, 'Transferring to phone');
        await _wrap(() => http.download('$_base/jobs/$remoteId/file', dest.path, headers: _auth).then((_) {}));
        files.add(dest);
      }
      final info = (status['info'] as Map?)?.cast<String, dynamic>();
      if (info != null) File('${workDir.path}/${info['id'] ?? 'server'}.info.json').writeAsStringSync(jsonEncode(info));
      // 3. the server may now delete its copy
      unawaited(http.dio.delete('$_base/jobs/$remoteId', options: Options(headers: _auth)).then((_) {}, onError: (_) {}));
      final audio = WorkDirReader.read(workDir);
      if (audio.files.isEmpty) {
        throw DownloadFailure(const DownloadError(DownloadErrorKind.unknown, 'The server returned no audio file.', retryable: true));
      }
      return EngineResult(files: audio.files, info: audio.info ?? info);
    } finally {
      _remoteJobs.remove(jobId);
    }
  }

  @override
  Future<void> cancel(String jobId) async {
    _cancelled.add(jobId);
    final remote = _remoteJobs[jobId];
    if (remote == null) return;
    try {
      await http.postJson('$_base/jobs/$remote/cancel', body: const {}, headers: _auth);
    } on HttpFailure {
      // the poll loop stops anyway
    }
  }
}

// ---------------------------------------------------------------------------
// Direct HTTP (Internet Archive, Audius, Jamendo, ccMixter, podcasts)
// ---------------------------------------------------------------------------

/// Plain file downloads for sources that hand out audio URLs - no yt-dlp involved.
class DirectHttpEngine {
  DirectHttpEngine(this.http);

  final HttpService http;
  final Map<String, CancelToken> _tokens = {};

  Future<EngineResult> download({
    required String jobId,
    required String url,
    required Directory workDir,
    MediaInfo? info,
    ProgressCallback? onProgress,
  }) async {
    workDir.createSync(recursive: true);
    final name = _fileName(url, info);
    final dest = File('${workDir.path}/$name');
    final token = _tokens[jobId] = CancelToken();
    try {
      await http.download(
        url,
        dest.path,
        cancel: token,
        onProgress: (received, total) {
          if (total > 0) onProgress?.call(received * 100 / total, 'Downloading');
        },
      );
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) throw DownloadFailure(const DownloadError(DownloadErrorKind.cancelled, 'Cancelled.'));
      final detail = [e.message, e.error?.toString(), e.type.name].whereType<String>().where((s) => s.isNotEmpty).join(' - ');
      throw DownloadFailure(DownloadError.classify(detail), detail);
    } on HttpFailure catch (e) {
      throw DownloadFailure(DownloadError.classify('HTTP Error ${e.statusCode}: ${e.message}'), e.message);
    } finally {
      _tokens.remove(jobId);
    }
    final infoJson = info == null
        ? null
        : {
            'id': info.id,
            'title': info.title,
            'artist': info.artist,
            'album': info.album,
            'duration': info.durationSec,
            'thumbnail': info.thumbnail,
            'webpage_url': info.url,
            'release_year': info.releaseYear,
            'license': info.license,
            'track_number': info.trackNumber,
          };
    return EngineResult(files: [dest], info: infoJson);
  }

  void cancel(String jobId) => _tokens[jobId]?.cancel();

  static String _fileName(String url, MediaInfo? info) {
    final path = Uri.tryParse(url)?.pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? 'audio';
    var name = Uri.decodeComponent(path).replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    if (!RegExp(r'\.(mp3|m4a|flac|ogg|opus|wav|aac)$', caseSensitive: false).hasMatch(name)) {
      name = '${info?.id ?? 'audio'}.mp3'.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    }
    return name;
  }
}

/// Chooses between the on-device engine and the companion server.
class EngineRouter {
  EngineRouter({required this.settings, required this.local, required this.server, required this.direct, bool? isAndroid}) : _isAndroid = isAndroid ?? Platform.isAndroid;

  final SettingsStore settings;
  final LocalYtDlpEngine local;
  final ServerYtDlpEngine server;
  final DirectHttpEngine direct;
  final bool _isAndroid;

  /// [DownloadEngineKind.auto]: on-device on Android, otherwise the server.
  DownloadEngine get current {
    switch (settings.engineKind) {
      case DownloadEngineKind.local:
        return local;
      case DownloadEngineKind.server:
        return server;
      case DownloadEngineKind.auto:
        if (_isAndroid) return local;
        return server;
    }
  }

  bool get serverConfigured => settings.serverUrl.isNotEmpty;
}
