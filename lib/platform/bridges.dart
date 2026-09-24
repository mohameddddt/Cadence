import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// Error reported by a native plugin (mirrors Kotlin's PlatformError codes).
class PlatformFailure implements Exception {
  PlatformFailure(this.code, this.message);

  final String code;
  final String message;

  /// Android 11+ refuses to write a file the app does not own until the user
  /// approves MediaStore.createWriteRequest.
  bool get needsPermission => code == 'needs_permission';
  bool get unsupportedFormat => code == 'unsupported_format';
  bool get cancelled => code == 'cancelled';

  @override
  String toString() => 'PlatformFailure($code: $message)';
}

Future<T> _guard<T>(Future<T> Function() f) async {
  try {
    return await f();
  } on PlatformException catch (e) {
    throw PlatformFailure(e.code, e.message ?? e.code);
  } on MissingPluginException {
    throw PlatformFailure('unavailable', 'This feature needs the Android app');
  }
}

const String _ns = 'dev.personal.musicplayer';

bool get isAndroid => !Platform.environment.containsKey('FLUTTER_TEST') && Platform.isAndroid;

// ---------------------------------------------------------------------------
// Tags
// ---------------------------------------------------------------------------

/// Everything a tag read can return. All fields optional.
class TagData {
  const TagData({
    this.title,
    this.artist,
    this.album,
    this.albumArtist,
    this.genre,
    this.comment,
    this.lyrics,
    this.isrc,
    this.date,
    this.trackNo,
    this.trackTotal,
    this.discNo,
    this.discTotal,
    this.mbRecordingId,
    this.mbReleaseTrackId,
    this.mbReleaseId,
    this.mbReleaseGroupId,
    this.mbArtistId,
    this.acoustId,
    this.replayGainTrack,
    this.replayGainAlbum,
    this.sourceUrl,
    this.durationMs,
    this.bitrate,
    this.sampleRate,
    this.format,
    this.hasArt = false,
  });

  final String? title;
  final String? artist;
  final String? album;
  final String? albumArtist;
  final String? genre;
  final String? comment;
  final String? lyrics;
  final String? isrc;
  final String? date;
  final int? trackNo;
  final int? trackTotal;
  final int? discNo;
  final int? discTotal;
  final String? mbRecordingId;
  final String? mbReleaseTrackId;
  final String? mbReleaseId;
  final String? mbReleaseGroupId;
  final String? mbArtistId;
  final String? acoustId;
  final String? replayGainTrack;
  final String? replayGainAlbum;
  final String? sourceUrl;
  final int? durationMs;
  final int? bitrate;
  final int? sampleRate;
  final String? format;
  final bool hasArt;

  int? get year {
    final d = date;
    if (d == null || d.length < 4) return null;
    return int.tryParse(d.substring(0, 4));
  }

  factory TagData.fromMap(Map<Object?, Object?> m) {
    String? s(String k) => m[k] as String?;
    int? i(String k) => (m[k] as num?)?.toInt();
    return TagData(
      title: s('title'),
      artist: s('artist'),
      album: s('album'),
      albumArtist: s('albumArtist'),
      genre: s('genre'),
      comment: s('comment'),
      lyrics: s('lyrics'),
      isrc: s('isrc'),
      date: s('date'),
      trackNo: i('trackNo'),
      trackTotal: i('trackTotal'),
      discNo: i('discNo'),
      discTotal: i('discTotal'),
      mbRecordingId: s('mbRecordingId'),
      mbReleaseTrackId: s('mbReleaseTrackId'),
      mbReleaseId: s('mbReleaseId'),
      mbReleaseGroupId: s('mbReleaseGroupId'),
      mbArtistId: s('mbArtistId'),
      acoustId: s('acoustId'),
      replayGainTrack: s('replayGainTrack'),
      replayGainAlbum: s('replayGainAlbum'),
      sourceUrl: s('sourceUrl'),
      durationMs: i('durationMs'),
      bitrate: i('bitrate'),
      sampleRate: i('sampleRate'),
      format: s('format'),
      hasArt: (m['hasArt'] as bool?) ?? false,
    );
  }
}

/// Values to write. A key that is present with a null/empty value deletes the field,
/// an absent key leaves it untouched.
class TagUpdate {
  TagUpdate([Map<String, Object?>? values]) : values = values ?? {};

  final Map<String, Object?> values;
  String? artPath;
  bool clearArt = false;

  TagUpdate set(String key, Object? value) {
    values[key] = value;
    return this;
  }

  bool get isEmpty => values.isEmpty && artPath == null && !clearArt;
}

class FileStat2 {
  const FileStat2({required this.size, required this.lastModified});
  final int size;
  final int lastModified; // seconds
}

abstract class TagsBridge {
  Future<TagData> read({String? path, String? uri});
  Future<FileStat2> write({String? path, String? uri, required TagUpdate update});
  Future<bool> extractArt({String? path, String? uri, required String out});
  Future<FileStat2> stat({String? path, String? uri});
}

class ChannelTagsBridge implements TagsBridge {
  static const _c = MethodChannel('$_ns/tags');

  @override
  Future<TagData> read({String? path, String? uri}) => _guard(() async {
        final m = await _c.invokeMapMethod<Object?, Object?>('read', {'path': path, 'uri': uri});
        return TagData.fromMap(m ?? const {});
      });

  @override
  Future<FileStat2> write({String? path, String? uri, required TagUpdate update}) => _guard(() async {
        final m = await _c.invokeMapMethod<String, Object?>('write', {
          'path': path,
          'uri': uri,
          'values': update.values,
          'artPath': update.artPath,
          'clearArt': update.clearArt,
        });
        return FileStat2(size: (m?['size'] as num?)?.toInt() ?? 0, lastModified: (m?['lastModified'] as num?)?.toInt() ?? 0);
      });

  @override
  Future<bool> extractArt({String? path, String? uri, required String out}) =>
      _guard(() async => (await _c.invokeMethod<bool>('extractArt', {'path': path, 'uri': uri, 'out': out})) ?? false);

  @override
  Future<FileStat2> stat({String? path, String? uri}) => _guard(() async {
        final m = await _c.invokeMapMethod<String, Object?>('stat', {'path': path, 'uri': uri});
        return FileStat2(size: (m?['size'] as num?)?.toInt() ?? 0, lastModified: (m?['lastModified'] as num?)?.toInt() ?? 0);
      });
}

// ---------------------------------------------------------------------------
// MediaStore / SAF
// ---------------------------------------------------------------------------

class AudioFileInfo {
  const AudioFileInfo({
    required this.uri,
    this.path,
    this.displayName,
    this.title,
    this.artist,
    this.album,
    this.albumArtist,
    this.genre,
    this.trackNo,
    this.discNo,
    this.year,
    this.durationMs,
    this.size = 0,
    this.dateModified = 0,
    this.dateAdded,
    this.mime,
    this.relativePath,
    this.bitrate,
  });

  final String uri;
  final String? path;
  final String? displayName;
  final String? title;
  final String? artist;
  final String? album;
  final String? albumArtist;
  final String? genre;
  final int? trackNo;
  final int? discNo;
  final int? year;
  final int? durationMs;
  final int size;
  final int dateModified; // seconds
  final int? dateAdded;
  final String? mime;
  final String? relativePath;
  final int? bitrate;

  /// Stable key for the DB: the real path when known, else the document URI.
  String get key => path ?? uri;

  String? get folder {
    final p = path;
    if (p != null && p.contains('/')) return p.substring(0, p.lastIndexOf('/'));
    return relativePath;
  }

  factory AudioFileInfo.fromMap(Map<Object?, Object?> m) {
    String? s(String k) => m[k] as String?;
    int? i(String k) => (m[k] as num?)?.toInt();
    return AudioFileInfo(
      uri: s('uri') ?? '',
      path: s('path'),
      displayName: s('displayName'),
      title: s('title'),
      artist: s('artist'),
      album: s('album'),
      albumArtist: s('albumArtist'),
      genre: s('genre'),
      trackNo: i('trackNo'),
      discNo: i('discNo'),
      year: i('year'),
      durationMs: i('durationMs'),
      size: i('size') ?? 0,
      dateModified: i('dateModified') ?? 0,
      dateAdded: i('dateAdded'),
      mime: s('mime'),
      relativePath: s('relativePath'),
      bitrate: i('bitrate'),
    );
  }
}

class PickedFolder {
  const PickedFolder({required this.uri, required this.name});
  final String uri;
  final String name;
}

class InsertedAudio {
  const InsertedAudio({required this.uri, required this.path, required this.displayName});
  final String uri;
  final String? path;
  final String displayName;
}

abstract class MediaStoreBridge {
  Future<List<AudioFileInfo>> queryAudio();
  Future<PickedFolder?> pickFolder();
  Future<List<PickedFolder>> persistedFolders();
  Future<void> releaseFolder(String uri);
  Future<List<AudioFileInfo>> scanTree(String uri);
  Future<InsertedAudio> insertAudio({
    required String src,
    required String displayName,
    required String relativeDir,
    required String mime,
  });
  Future<InsertedAudio> moveAudio({required String uri, required String relativeDir, required String displayName});
  Future<bool> deleteAudio(String uri);
  Future<bool> requestWrite(List<String> uris);
  Future<void> rescan(String path);
  Stream<void> get changes;
}

class ChannelMediaStoreBridge implements MediaStoreBridge {
  static const _c = MethodChannel('$_ns/mediastore');
  static const _e = EventChannel('$_ns/mediastore_events');

  @override
  Future<List<AudioFileInfo>> queryAudio() => _guard(() async {
        final rows = await _c.invokeListMethod<Map<Object?, Object?>>('queryAudio') ?? const [];
        return rows.map(AudioFileInfo.fromMap).toList();
      });

  @override
  Future<PickedFolder?> pickFolder() => _guard(() async {
        final m = await _c.invokeMapMethod<String, String>('pickFolder');
        return m == null ? null : PickedFolder(uri: m['uri']!, name: m['name'] ?? 'Folder');
      });

  @override
  Future<List<PickedFolder>> persistedFolders() => _guard(() async {
        final rows = await _c.invokeListMethod<Map<Object?, Object?>>('persistedFolders') ?? const [];
        return [for (final r in rows) PickedFolder(uri: r['uri'] as String, name: (r['name'] as String?) ?? 'Folder')];
      });

  @override
  Future<void> releaseFolder(String uri) => _guard(() => _c.invokeMethod('releaseFolder', {'uri': uri}));

  @override
  Future<List<AudioFileInfo>> scanTree(String uri) => _guard(() async {
        final rows = await _c.invokeListMethod<Map<Object?, Object?>>('scanTree', {'uri': uri}) ?? const [];
        return rows.map(AudioFileInfo.fromMap).toList();
      });

  @override
  Future<InsertedAudio> insertAudio({
    required String src,
    required String displayName,
    required String relativeDir,
    required String mime,
  }) =>
      _guard(() async {
        final m = await _c.invokeMapMethod<String, Object?>('insertAudio', {
          'src': src,
          'displayName': displayName,
          'relativeDir': relativeDir,
          'mime': mime,
        });
        return InsertedAudio(uri: m!['uri'] as String, path: m['path'] as String?, displayName: (m['displayName'] as String?) ?? displayName);
      });

  @override
  Future<InsertedAudio> moveAudio({required String uri, required String relativeDir, required String displayName}) => _guard(() async {
        final m = await _c.invokeMapMethod<String, Object?>('moveAudio', {'uri': uri, 'relativeDir': relativeDir, 'displayName': displayName});
        return InsertedAudio(uri: m!['uri'] as String, path: m['path'] as String?, displayName: (m['displayName'] as String?) ?? displayName);
      });

  @override
  Future<bool> deleteAudio(String uri) => _guard(() async => (await _c.invokeMethod<bool>('deleteAudio', {'uri': uri})) ?? false);

  @override
  Future<bool> requestWrite(List<String> uris) =>
      _guard(() async => (await _c.invokeMethod<bool>('requestWrite', {'uris': uris})) ?? false);

  @override
  Future<void> rescan(String path) => _guard(() => _c.invokeMethod('rescan', {'path': path}));

  @override
  Stream<void> get changes => _e.receiveBroadcastStream().map((_) {});
}

// ---------------------------------------------------------------------------
// Decoder
// ---------------------------------------------------------------------------

class DecodedAudio {
  const DecodedAudio({required this.sampleRate, required this.channels, required this.frames, required this.sourceSampleRate});
  final int sampleRate;
  final int channels;
  final int frames;
  final int sourceSampleRate;
}

abstract class DecoderBridge {
  /// Decodes to raw s16le PCM in [out]. [sampleRate] 0 keeps the source rate.
  Future<DecodedAudio> decode({
    String? path,
    String? uri,
    required String out,
    int sampleRate = 0,
    int channels = 1,
    int maxSeconds = 0,
  });
}

class ChannelDecoderBridge implements DecoderBridge {
  static const _c = MethodChannel('$_ns/decoder');

  @override
  Future<DecodedAudio> decode({
    String? path,
    String? uri,
    required String out,
    int sampleRate = 0,
    int channels = 1,
    int maxSeconds = 0,
  }) =>
      _guard(() async {
        final m = await _c.invokeMapMethod<String, Object?>('decode', {
          'path': path,
          'uri': uri,
          'out': out,
          'sampleRate': sampleRate,
          'channels': channels,
          'maxSeconds': maxSeconds,
        });
        return DecodedAudio(
          sampleRate: (m!['sampleRate'] as num).toInt(),
          channels: (m['channels'] as num).toInt(),
          frames: (m['frames'] as num).toInt(),
          sourceSampleRate: (m['sourceSampleRate'] as num).toInt(),
        );
      });
}

// ---------------------------------------------------------------------------
// yt-dlp
// ---------------------------------------------------------------------------

class YtDlpResult {
  const YtDlpResult({required this.exitCode, required this.out, required this.err});
  final int exitCode;
  final String out;
  final String err;
}

class YtDlpProgress {
  const YtDlpProgress({required this.jobId, required this.percent, this.etaSeconds, this.line = ''});
  final String jobId;
  final double percent; // 0..100
  final int? etaSeconds;
  final String line;
}

abstract class YtDlpBridge {
  Future<String> init();
  Future<String> version();
  Future<({String status, String version})> update(String channel);
  Future<YtDlpResult> run(List<String> args, {String? processId});
  Future<YtDlpResult> download(String jobId, List<String> args);
  Future<bool> cancel(String jobId);
  Future<void> setForeground({required bool active, String title = 'Downloading', String text = '', int progress = -1});
  Stream<YtDlpProgress> get progress;
}

class ChannelYtDlpBridge implements YtDlpBridge {
  static const _c = MethodChannel('$_ns/ytdlp');
  static const _e = EventChannel('$_ns/ytdlp_events');

  @override
  Future<String> init() => _guard(() async => (await _c.invokeMethod<String>('init')) ?? '');

  @override
  Future<String> version() => _guard(() async => (await _c.invokeMethod<String>('version')) ?? '');

  @override
  Future<({String status, String version})> update(String channel) => _guard(() async {
        final m = await _c.invokeMapMethod<String, String>('update', {'channel': channel});
        return (status: m?['status'] ?? 'DONE', version: m?['version'] ?? '');
      });

  @override
  Future<YtDlpResult> run(List<String> args, {String? processId}) => _guard(() async {
        final m = await _c.invokeMapMethod<String, Object?>('run', {'args': args, 'processId': processId});
        return YtDlpResult(exitCode: (m!['exitCode'] as num).toInt(), out: (m['out'] as String?) ?? '', err: (m['err'] as String?) ?? '');
      });

  @override
  Future<YtDlpResult> download(String jobId, List<String> args) => _guard(() async {
        final m = await _c.invokeMapMethod<String, Object?>('download', {'jobId': jobId, 'args': args});
        return YtDlpResult(exitCode: (m!['exitCode'] as num).toInt(), out: (m['out'] as String?) ?? '', err: (m['err'] as String?) ?? '');
      });

  @override
  Future<bool> cancel(String jobId) => _guard(() async => (await _c.invokeMethod<bool>('cancel', {'jobId': jobId})) ?? false);

  @override
  Future<void> setForeground({required bool active, String title = 'Downloading', String text = '', int progress = -1}) =>
      _guard(() => _c.invokeMethod('setForeground', {'active': active, 'title': title, 'text': text, 'progress': progress}));

  @override
  Stream<YtDlpProgress> get progress => _e.receiveBroadcastStream().map((e) {
        final m = (e as Map).cast<String, Object?>();
        return YtDlpProgress(
          jobId: m['jobId'] as String,
          percent: (m['progress'] as num).toDouble(),
          etaSeconds: (m['eta'] as num?)?.toInt(),
          line: (m['line'] as String?) ?? '',
        );
      });
}

// ---------------------------------------------------------------------------
// System
// ---------------------------------------------------------------------------

class SharedContent {
  const SharedContent({required this.type, required this.value});

  /// "text" (a shared link/text) or "audio" (a VIEW intent for an audio file).
  final String type;
  final String value;
}

abstract class SystemBridge {
  Future<int> sdkInt();
  Future<void> notify({required int id, required String title, required String body});
  Future<bool> isIgnoringBatteryOptimizations();
  Future<bool> requestIgnoreBatteryOptimizations();
  Future<SharedContent?> takeInitialShare();
  Stream<SharedContent> get shares;
}

class ChannelSystemBridge implements SystemBridge {
  ChannelSystemBridge() {
    _c.setMethodCallHandler((call) async {
      if (call.method == 'onShare') {
        final m = (call.arguments as Map).cast<String, Object?>();
        _shares.add(SharedContent(type: m['type'] as String, value: m['value'] as String));
      }
    });
  }

  static const _c = MethodChannel('$_ns/system');
  final StreamController<SharedContent> _shares = StreamController<SharedContent>.broadcast();

  @override
  Future<int> sdkInt() => _guard(() async => (await _c.invokeMethod<int>('sdkInt')) ?? 0);

  @override
  Future<void> notify({required int id, required String title, required String body}) =>
      _guard(() => _c.invokeMethod('notify', {'id': id, 'title': title, 'body': body}));

  @override
  Future<bool> isIgnoringBatteryOptimizations() =>
      _guard(() async => (await _c.invokeMethod<bool>('isIgnoringBatteryOptimizations')) ?? false);

  @override
  Future<bool> requestIgnoreBatteryOptimizations() =>
      _guard(() async => (await _c.invokeMethod<bool>('requestIgnoreBatteryOptimizations')) ?? false);

  @override
  Future<SharedContent?> takeInitialShare() => _guard(() async {
        final m = await _c.invokeMapMethod<String, Object?>('takeInitialShare');
        return m == null ? null : SharedContent(type: m['type'] as String, value: m['value'] as String);
      });

  @override
  Stream<SharedContent> get shares => _shares.stream;
}

/// Bundle of every native bridge, so services take one dependency and tests swap it whole.
class Bridges {
  Bridges({
    TagsBridge? tags,
    MediaStoreBridge? mediaStore,
    DecoderBridge? decoder,
    YtDlpBridge? ytDlp,
    SystemBridge? system,
  })  : tags = tags ?? ChannelTagsBridge(),
        mediaStore = mediaStore ?? ChannelMediaStoreBridge(),
        decoder = decoder ?? ChannelDecoderBridge(),
        ytDlp = ytDlp ?? ChannelYtDlpBridge(),
        system = system ?? ChannelSystemBridge();

  final TagsBridge tags;
  final MediaStoreBridge mediaStore;
  final DecoderBridge decoder;
  final YtDlpBridge ytDlp;
  final SystemBridge system;
}
