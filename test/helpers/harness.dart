import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:musicplayer/core/library/library_repository.dart';
import 'package:musicplayer/core/net/http_service.dart';
import 'package:musicplayer/core/settings/settings_store.dart';
import 'package:musicplayer/features/cover/cover_providers.dart';
import 'package:musicplayer/features/cover/cover_service.dart';
import 'package:musicplayer/features/cover/image_processing.dart';
import 'package:musicplayer/features/downloader/download_manager.dart';
import 'package:musicplayer/features/downloader/download_pipeline.dart';
import 'package:musicplayer/features/downloader/engines.dart';
import 'package:musicplayer/features/downloader/job_repository.dart';
import 'package:musicplayer/features/lyrics/lyrics_clients.dart';
import 'package:musicplayer/features/lyrics/lyrics_service.dart';
import 'package:musicplayer/features/metadata/acoustid_client.dart';
import 'package:musicplayer/features/metadata/fingerprint_service.dart';
import 'package:musicplayer/features/metadata/identify_service.dart';
import 'package:musicplayer/features/metadata/musicbrainz_client.dart';
import 'package:musicplayer/features/metadata/tag_writer.dart';
import 'package:musicplayer/features/playback/loudness_service.dart';
import 'package:musicplayer/platform/bridges.dart';

import 'fake_http.dart';
import 'fakes.dart';
import 'test_db.dart';

class ToggleNetwork implements NetworkGuard {
  bool unmetered = true;
  final StreamController<void> _c = StreamController<void>.broadcast();

  void set(bool v) {
    unmetered = v;
    _c.add(null);
  }

  @override
  Future<bool> isUnmetered() async => unmetered;

  @override
  Stream<void> get changes => _c.stream;
}

Uint8List jpegBytes(int w, int h) {
  final image = img.Image(width: w, height: h);
  img.fill(image, color: img.ColorRgb8(20, 120, 200));
  return Uint8List.fromList(img.encodeJpg(image, quality: 80));
}

/// Everything wired together with fakes at the platform/network edge.
class Harness {
  Harness._();

  late final LibraryRepository repo;
  late final JobRepository jobs;
  late final FakeBridges bridges;
  late final FakeHttpAdapter net;
  late final SettingsStore settings;
  late final ToggleNetwork network;
  late final Directory root;
  late final DownloadManager manager;
  late final IdentifyService identify;
  late final CoverService covers;
  late final LyricsService lyrics;
  late final DownloadPipeline pipeline;
  late final EngineRouter router;
  late final HttpService http;

  static Future<Harness> create({Map<String, Object> prefs = const {}}) async {
    final h = Harness._();
    h.root = Directory.systemTemp.createTempSync('harness');
    h.repo = await openTestRepo();
    h.jobs = JobRepository(h.repo.appDb);
    h.bridges = FakeBridges();
    h.net = FakeHttpAdapter();
    h.settings = await testSettings({
      // fast tests: no lyrics/cover network unless a test wants it
      'dl.autoLyrics': false,
      'dl.autoCover': false,
      'dl.autoReplayGain': false,
      ...prefs,
    });
    h.network = ToggleNetwork();
    h.http = fakeHttp(h.net);
    final tagWriter = TagWriter(repo: h.repo, bridges: h.bridges);
    h.identify = IdentifyService(
      repo: h.repo,
      settings: h.settings,
      musicBrainz: MusicBrainzClient(h.http),
      acoustId: AcoustIdClient(h.http, apiKey: () => h.settings.acoustIdKey),
      fingerprints: FingerprintService(decoder: h.bridges.fakeDecoder, tempDir: () => Directory('${h.root.path}/fp')),
      tagWriter: tagWriter,
      bridges: h.bridges,
    );
    h.covers = CoverService(
      repo: h.repo,
      http: h.http,
      bridges: h.bridges,
      settings: h.settings,
      providers: {
        'caa': CoverArtArchiveProvider(h.http),
        'caa-group': CoverArtArchiveProvider(h.http, byReleaseGroup: true),
        'itunes': ITunesCoverProvider(h.http),
        'deezer': DeezerCoverProvider(h.http),
      },
      tagWriter: tagWriter,
      coversDir: () => Directory('${h.root.path}/covers'),
      processor: (b) async => ImageProcessing.processCover(b),
    );
    h.lyrics = LyricsService(
      repo: h.repo,
      bridges: h.bridges,
      settings: h.settings,
      lrclib: LrclibClient(h.http),
      genius: GeniusClient(h.http, token: () => h.settings.geniusToken),
      tagWriter: tagWriter,
    );
    final loudness = LoudnessService(repo: h.repo, decoder: h.bridges.fakeDecoder, tagWriter: tagWriter, tempDir: () => Directory('${h.root.path}/rg'));
    h.pipeline = DownloadPipeline(
      repo: h.repo,
      jobs: h.jobs,
      bridges: h.bridges,
      settings: h.settings,
      identify: h.identify,
      covers: h.covers,
      lyrics: h.lyrics,
      loudness: loudness,
    );
    h.router = EngineRouter(
      settings: h.settings,
      local: LocalYtDlpEngine(h.bridges.fakeYt, h.settings),
      server: ServerYtDlpEngine(h.http, baseUrl: () => h.settings.serverUrl, token: () => h.settings.serverToken, pollInterval: const Duration(milliseconds: 5)),
      direct: DirectHttpEngine(h.http),
      isAndroid: true,
    );
    h.manager = DownloadManager(
      repo: h.repo,
      jobs: h.jobs,
      settings: h.settings,
      router: h.router,
      pipeline: h.pipeline,
      bridges: h.bridges,
      network: h.network,
      tempDir: () => Directory('${h.root.path}/tmp')..createSync(recursive: true),
    );
    return h;
  }

  /// Makes the fake yt-dlp "download" [name] with [content] and an info json.
  void fakeYtDlpWrites({
    String name = 'abc123.m4a',
    List<int>? content,
    Map<String, dynamic>? info,
    void Function(String jobId)? onStart,
  }) {
    bridges.fakeYt.onDownload = (jobId, args) async {
      onStart?.call(jobId);
      final dir = args[args.indexOf('-P') + 1];
      Directory(dir).createSync(recursive: true);
      File('$dir/$name').writeAsBytesSync(content ?? List<int>.generate(2048, (i) => i % 251));
      final id = name.substring(0, name.lastIndexOf('.'));
      File('$dir/$id.info.json').writeAsStringSync(jsonEncode(info ?? {'id': id, 'title': 'Bohemian Rhapsody (Official Video) [4K]', 'uploader': 'Queen Official', 'duration': 355, 'webpage_url': args.last}));
      return const YtDlpResult(exitCode: 0, out: '', err: '');
    };
  }

  /// Waits until [test] is true or fails after [timeout].
  Future<void> until(Future<bool> Function() test, {Duration timeout = const Duration(seconds: 10)}) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      if (await test()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    throw StateError('condition not met within $timeout');
  }

  Future<void> dispose() async {
    await manager.settle();
    manager.dispose();
    await repo.appDb.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}
