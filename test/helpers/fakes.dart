import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:musicplayer/core/settings/settings_store.dart';
import 'package:musicplayer/platform/bridges.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<SettingsStore> testSettings([Map<String, Object> initial = const {}]) async {
  SharedPreferences.setMockInitialValues(initial);
  return SettingsStore.load();
}

class FakeTagsBridge implements TagsBridge {
  final Map<String, TagData> byKey = {};
  final Set<String> failing = {};
  final List<({String? path, String? uri, TagUpdate update})> writes = [];
  PlatformFailure? writeFailure;
  int reads = 0;

  String _key(String? path, String? uri) => path ?? uri ?? '';

  @override
  Future<TagData> read({String? path, String? uri}) async {
    reads++;
    final k = _key(path, uri);
    if (failing.contains(k)) throw PlatformFailure('error', 'cannot parse');
    return byKey[k] ?? const TagData();
  }

  @override
  Future<FileStat2> write({String? path, String? uri, required TagUpdate update}) async {
    if (writeFailure != null) throw writeFailure!;
    writes.add((path: path, uri: uri, update: update));
    return const FileStat2(size: 1234, lastModified: 4242);
  }

  final Map<String, bool> art = {};

  @override
  Future<bool> extractArt({String? path, String? uri, required String out}) async => art[_key(path, uri)] ?? false;

  @override
  Future<FileStat2> stat({String? path, String? uri}) async => const FileStat2(size: 1234, lastModified: 4242);
}

class FakeMediaStoreBridge implements MediaStoreBridge {
  List<AudioFileInfo> audio = [];
  List<PickedFolder> folders = [];
  final Map<String, List<AudioFileInfo>> trees = {};
  bool failQuery = false;

  /// Runs while a listing is in flight - lets tests change the database mid-scan.
  Future<void> Function()? duringQuery;
  final StreamController<void> _changes = StreamController<void>.broadcast();
  final List<({String src, String displayName, String relativeDir, String mime})> inserted = [];
  final List<String> deleted = [];
  final List<String> rescanned = [];
  bool writeGranted = true;
  int writeRequests = 0;

  void fireChange() => _changes.add(null);

  @override
  Future<List<AudioFileInfo>> queryAudio() async {
    if (failQuery) throw PlatformFailure('error', 'permission denied');
    final snapshot = List.of(audio);
    await duringQuery?.call();
    return snapshot;
  }

  @override
  Future<PickedFolder?> pickFolder() async => folders.isEmpty ? null : folders.first;

  @override
  Future<List<PickedFolder>> persistedFolders() async => List.of(folders);

  @override
  Future<void> releaseFolder(String uri) async => folders.removeWhere((f) => f.uri == uri);

  @override
  Future<List<AudioFileInfo>> scanTree(String uri) async => List.of(trees[uri] ?? const []);

  @override
  Future<InsertedAudio> insertAudio({
    required String src,
    required String displayName,
    required String relativeDir,
    required String mime,
  }) async {
    inserted.add((src: src, displayName: displayName, relativeDir: relativeDir, mime: mime));
    final path = '/storage/emulated/0/Music/$relativeDir/$displayName';
    return InsertedAudio(uri: 'content://media/external/audio/media/${inserted.length}', path: path, displayName: displayName);
  }

  final List<({String uri, String relativeDir, String displayName})> moved = [];

  @override
  Future<InsertedAudio> moveAudio({required String uri, required String relativeDir, required String displayName}) async {
    moved.add((uri: uri, relativeDir: relativeDir, displayName: displayName));
    return InsertedAudio(uri: uri, path: '/storage/emulated/0/Music/$relativeDir/$displayName', displayName: displayName);
  }

  @override
  Future<bool> deleteAudio(String uri) async {
    deleted.add(uri);
    return true;
  }

  @override
  Future<bool> requestWrite(List<String> uris) async {
    writeRequests++;
    return writeGranted;
  }

  @override
  Future<void> rescan(String path) async => rescanned.add(path);

  @override
  Stream<void> get changes => _changes.stream;
}

class FakeDecoderBridge implements DecoderBridge {
  /// When set, [decode] writes this PCM (s16le) and reports [rate]; otherwise it is "unavailable".
  Int16List? pcm;
  int rate = 11025;
  int channels = 1;

  @override
  Future<DecodedAudio> decode({
    String? path,
    String? uri,
    required String out,
    int sampleRate = 0,
    int channels = 1,
    int maxSeconds = 0,
  }) async {
    final data = pcm;
    if (data == null) throw PlatformFailure('unavailable', 'no decoder in tests');
    File(out).writeAsBytesSync(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
    final ch = this.channels;
    return DecodedAudio(sampleRate: rate, channels: ch, frames: data.length ~/ ch, sourceSampleRate: rate);
  }
}

class FakeYtDlpBridge implements YtDlpBridge {
  final List<List<String>> runs = [];
  final List<({String jobId, List<String> args})> downloads = [];
  YtDlpResult Function(List<String> args)? onRun;
  Future<YtDlpResult> Function(String jobId, List<String> args)? onDownload;
  final StreamController<YtDlpProgress> _progress = StreamController<YtDlpProgress>.broadcast();
  final List<bool> foreground = [];
  final List<String> cancelled = [];

  void emit(YtDlpProgress p) => _progress.add(p);

  @override
  Future<String> init() async => '2025.01.01';

  @override
  Future<String> version() async => '2025.01.01';

  @override
  Future<({String status, String version})> update(String channel) async => (status: 'DONE', version: '2025.02.02');

  @override
  Future<YtDlpResult> run(List<String> args, {String? processId}) async {
    runs.add(args);
    return onRun?.call(args) ?? const YtDlpResult(exitCode: 0, out: '', err: '');
  }

  @override
  Future<YtDlpResult> download(String jobId, List<String> args) async {
    downloads.add((jobId: jobId, args: args));
    return onDownload != null ? onDownload!(jobId, args) : const YtDlpResult(exitCode: 0, out: '', err: '');
  }

  @override
  Future<bool> cancel(String jobId) async {
    cancelled.add(jobId);
    return true;
  }

  @override
  Future<void> setForeground({required bool active, String title = 'Downloading', String text = '', int progress = -1}) async =>
      foreground.add(active);

  @override
  Stream<YtDlpProgress> get progress => _progress.stream;
}

class FakeSystemBridge implements SystemBridge {
  final List<({int id, String title, String body})> notifications = [];
  final StreamController<SharedContent> _shares = StreamController<SharedContent>.broadcast();
  SharedContent? initial;

  void share(SharedContent c) => _shares.add(c);

  @override
  Future<int> sdkInt() async => 34;

  @override
  Future<void> notify({required int id, required String title, required String body}) async =>
      notifications.add((id: id, title: title, body: body));

  @override
  Future<bool> isIgnoringBatteryOptimizations() async => false;

  @override
  Future<bool> requestIgnoreBatteryOptimizations() async => true;

  @override
  Future<SharedContent?> takeInitialShare() async {
    final s = initial;
    initial = null;
    return s;
  }

  @override
  Stream<SharedContent> get shares => _shares.stream;
}

class FakeBridges extends Bridges {
  FakeBridges._(this.fakeTags, this.fakeStore, this.fakeDecoder, this.fakeYt, this.fakeSystem)
      : super(tags: fakeTags, mediaStore: fakeStore, decoder: fakeDecoder, ytDlp: fakeYt, system: fakeSystem);

  factory FakeBridges() =>
      FakeBridges._(FakeTagsBridge(), FakeMediaStoreBridge(), FakeDecoderBridge(), FakeYtDlpBridge(), FakeSystemBridge());

  final FakeTagsBridge fakeTags;
  final FakeMediaStoreBridge fakeStore;
  final FakeDecoderBridge fakeDecoder;
  final FakeYtDlpBridge fakeYt;
  final FakeSystemBridge fakeSystem;
}
