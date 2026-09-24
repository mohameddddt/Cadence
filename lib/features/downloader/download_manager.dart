import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../../core/library/library_repository.dart';
import '../../core/models/library_models.dart';
import '../../core/models/track.dart';
import '../../core/settings/settings_store.dart';
import '../../platform/bridges.dart';
import '../sources/source_provider.dart';
import 'download_models.dart';
import 'download_pipeline.dart';
import 'engines.dart';
import 'job_repository.dart';
import 'source_detect.dart';

/// Reports whether downloads may use the current connection (Wi-Fi only setting).
abstract class NetworkGuard {
  Future<bool> isUnmetered();
  Stream<void> get changes;
}

class ConnectivityNetworkGuard implements NetworkGuard {
  final Connectivity _c = Connectivity();

  @override
  Future<bool> isUnmetered() async {
    final r = await _c.checkConnectivity();
    return r.contains(ConnectivityResult.wifi) || r.contains(ConnectivityResult.ethernet);
  }

  @override
  Stream<void> get changes => _c.onConnectivityChanged.map((_) {});
}

class AlwaysOnlineGuard implements NetworkGuard {
  @override
  Future<bool> isUnmetered() async => true;

  @override
  Stream<void> get changes => const Stream.empty();
}

/// What happened when the user asked to download something.
class EnqueueResult {
  const EnqueueResult._(this.jobId, this.duplicate, this.alreadyQueued);

  final int? jobId;

  /// A track with the same source URL / recording already exists.
  final Track? duplicate;
  final bool alreadyQueued;

  factory EnqueueResult.queued(int id) => EnqueueResult._(id, null, false);
  factory EnqueueResult.duplicate(Track t) => EnqueueResult._(null, t, false);
  factory EnqueueResult.existing(int id) => EnqueueResult._(id, null, true);

  bool get isNew => jobId != null && !alreadyQueued;
}

class DownloadEvent {
  const DownloadEvent(this.kind, this.job, {this.message});

  /// finished | failed | allDone
  final String kind;
  final DownloadJob? job;
  final String? message;
}

class _Active {
  _Active(this.job, this.engine);
  final DownloadJob job;
  final String engine;
  double progress = 0;
  bool cancelRequested = false;
}

/// Download queue: persistence, concurrency, foreground service, retries and the
/// post-processing pipeline. Survives the app being killed - interrupted jobs resume.
class DownloadManager extends ChangeNotifier {
  DownloadManager({
    required this.repo,
    required this.jobs,
    required this.settings,
    required this.router,
    required this.pipeline,
    required this.bridges,
    required this.network,
    required this.tempDir,
  });

  final LibraryRepository repo;
  final JobRepository jobs;
  final SettingsStore settings;
  final EngineRouter router;
  final DownloadPipeline pipeline;
  final Bridges bridges;
  final NetworkGuard network;
  final Directory Function() tempDir;

  final Map<int, _Active> _active = {};
  final Set<Future<void>> _runs = {};
  final StreamController<DownloadEvent> _events = StreamController<DownloadEvent>.broadcast();
  StreamSubscription<void>? _netSub;
  bool _pumping = false;
  bool _autoUpdatedThisSession = false;
  int _finishedSinceIdle = 0;
  int _failedSinceIdle = 0;

  Stream<DownloadEvent> get events => _events.stream;
  int get activeCount => _active.length;
  bool get isBusy => _active.isNotEmpty;

  /// In-memory progress (0..100) of running jobs, for smooth UI without database churn.
  double progressOf(int jobId) => _active[jobId]?.progress ?? 0;

  /// Completes when every running job (and its clean-up) has finished. Mainly for tests and
  /// orderly shutdown.
  Future<void> settle() async {
    while (_runs.isNotEmpty) {
      await Future.wait(_runs.toList());
    }
  }

  // ------------------------------------------------------------- lifecycle

  Future<void> start() async {
    await jobs.resetInterrupted();
    _netSub?.cancel();
    _netSub = network.changes.listen((_) => pump());
    unawaited(pump());
  }

  @override
  void dispose() {
    _netSub?.cancel();
    _events.close();
    super.dispose();
  }

  // --------------------------------------------------------------- enqueue

  /// Queue a URL (paste box, share intent, search result). Playlists must be expanded by the
  /// caller first - see [enqueueMany].
  Future<EnqueueResult> enqueueUrl(
    String url, {
    String? title,
    String? artist,
    String? thumbnail,
    bool force = false,
    String? directUrl,
    RemoteHint? hint,
    DownloadOptions? options,
  }) async {
    final info = detectSource(url);
    final canonical = directUrl ?? info.canonicalUrl;
    // Jobs are keyed by the canonical URL so "youtu.be/x?si=..." and "youtube.com/watch?v=x"
    // are recognised as the same download. Direct files keep their file URL.
    final jobUrl = directUrl != null ? url : (info.canonicalUrl.isEmpty ? url : info.canonicalUrl);
    final running = await jobs.activeForUrl(jobUrl);
    if (running != null) return EnqueueResult.existing(running.id);
    if (!force) {
      final dup = await repo.trackBySourceUrl(canonical);
      if (dup != null) return EnqueueResult.duplicate(dup);
    }
    final opts = (options ?? DownloadOptions.fromSettings(settings)).toJson();
    final id = await jobs.create(
      url: jobUrl,
      sourceType: (hint?.source ?? info.source).name,
      title: title,
      artist: artist,
      thumbnail: thumbnail,
      options: {
        ...opts,
        if (force) 'force': true,
        if (directUrl != null) 'direct': directUrl,
        if (directUrl != null) 'canonical': canonical,
        if (hint != null) 'hint': hint.toJson(),
      },
    );
    unawaited(pump());
    return EnqueueResult.queued(id);
  }

  /// Queue a search result / archive track. Direct files skip yt-dlp entirely.
  Future<EnqueueResult> enqueueRemote(RemoteTrack t, {bool force = false}) {
    return enqueueUrl(
      t.downloadUrl ?? t.pageUrl,
      title: t.title,
      artist: t.artist,
      thumbnail: t.thumbnail,
      force: force,
      directUrl: t.downloadUrl,
      hint: RemoteHint(
        title: t.title,
        // A provider's title beats the file's tags - unless it is only a guess from the file name.
        trackTitle: t.downloadUrl != null && t.extra['titleGuess'] != true ? t.title : null,
        artist: t.artist,
        album: t.album,
        year: t.year,
        trackNumber: t.trackNumber,
        source: t.source,
        thumbnail: t.thumbnail,
      ),
    );
  }

  Future<List<EnqueueResult>> enqueueMany(Iterable<RemoteTrack> tracks, {bool force = false}) async {
    final out = <EnqueueResult>[];
    for (final t in tracks) {
      out.add(await enqueueRemote(t, force: force));
    }
    return out;
  }

  // ------------------------------------------------------------ user actions

  Future<void> cancel(int jobId) async {
    final a = _active[jobId];
    if (a != null) {
      a.cancelRequested = true;
      await _engineFor(a.job).cancel(jobId.toString());
      router.direct.cancel(jobId.toString());
    } else {
      await jobs.update(jobId, status: JobStatus.cancelled, stage: 'Cancelled', finished: true);
    }
  }

  Future<void> retry(int jobId) async {
    await jobs.update(jobId, status: JobStatus.queued, progress: 0, stage: 'Queued', clearError: true);
    unawaited(pump());
  }

  Future<void> remove(int jobId) async {
    if (_active.containsKey(jobId)) await cancel(jobId);
    await jobs.delete(jobId);
  }

  Future<void> clearFinished() => jobs.clearFinished();

  Future<void> retryAllFailed() async {
    for (final j in await jobs.all(statuses: [JobStatus.failed])) {
      await jobs.update(j.id, status: JobStatus.queued, progress: 0, stage: 'Queued', clearError: true, notify: false);
    }
    jobs.appDb.notifyChanged();
    unawaited(pump());
  }

  // -------------------------------------------------------------------- pump

  DownloadEngine _engineFor(DownloadJob job) => router.current;

  Future<void> pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_active.length < settings.maxConcurrent) {
        final queued = (await jobs.queued()).where((j) => !_active.containsKey(j.id)).toList();
        if (queued.isEmpty) break;
        if (settings.wifiOnly && !await network.isUnmetered()) {
          for (final j in queued) {
            await jobs.update(j.id, stage: 'Waiting for Wi-Fi', notify: false);
          }
          jobs.appDb.notifyChanged();
          break;
        }
        final job = queued.first;
        final engineId = job.options['direct'] != null ? 'direct' : _engineFor(job).id;
        final active = _active[job.id] = _Active(job, engineId);
        late final Future<void> run;
        run = _run(active).whenComplete(() {
          _runs.remove(run);
        });
        _runs.add(run);
        unawaited(run);
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      _pumping = false;
    }
    await _updateForeground();
  }

  Future<void> _run(_Active a) async {
    final job = a.job;
    final jobKey = job.id.toString();
    final workDir = Directory('${tempDir().path}/dl/$jobKey');
    var lastWrite = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      await jobs.update(job.id, status: JobStatus.running, stage: 'Starting', progress: 0, clearError: true);
      await _updateForeground();
      final options = DownloadOptions.fromJson(job.options);
      final info = detectSource(job.url);

      void onProgress(double percent, String? stage) {
        a.progress = percent;
        final now = DateTime.now();
        if (now.difference(lastWrite) > const Duration(milliseconds: 600)) {
          lastWrite = now;
          jobs.update(job.id, progress: percent, stage: stage, notify: true);
          _updateForeground();
        }
        notifyListeners();
      }

      late EngineResult result;
      final direct = job.options['direct'] as String?;
      if (direct != null) {
        result = await router.direct.download(jobId: jobKey, url: direct, workDir: workDir, onProgress: onProgress);
      } else {
        final engine = _engineFor(job);
        try {
          result = await engine.download(
            jobId: jobKey,
            url: job.url,
            source: info.source,
            workDir: workDir,
            options: options,
            onProgress: onProgress,
          );
        } on DownloadFailure catch (f) {
          // yt-dlp breaks whenever YouTube changes: update once and try again.
          if (f.error.kind == DownloadErrorKind.needsUpdate && settings.autoUpdateYtDlp && !_autoUpdatedThisSession && !a.cancelRequested) {
            _autoUpdatedThisSession = true;
            await jobs.update(job.id, stage: 'Updating yt-dlp');
            await engine.update(settings.ytDlpChannel);
            await settings.setLastYtDlpUpdate(DateTime.now());
            if (workDir.existsSync()) workDir.deleteSync(recursive: true);
            result = await engine.download(jobId: jobKey, url: job.url, source: info.source, workDir: workDir, options: options, onProgress: onProgress);
          } else {
            rethrow;
          }
        }
      }
      if (a.cancelRequested) throw DownloadFailure(const DownloadError(DownloadErrorKind.cancelled, 'Cancelled.'));
      await jobs.appendLog(job.id, result.log);

      await jobs.update(job.id, status: JobStatus.postprocessing, stage: 'Post-processing', progress: 100);
      final hint = job.options['hint'] is Map ? RemoteHint.fromJson((job.options['hint'] as Map).cast<String, dynamic>()) : null;
      final r = await pipeline.process((await jobs.byId(job.id)) ?? job, result, hint: hint);
      final note = r.notes.isEmpty ? null : r.notes.join('\n');
      if (r.duplicateOf != null) {
        await jobs.update(job.id, status: JobStatus.done, stage: 'Already in library', trackId: r.duplicateOf!.id, progress: 100, finished: true);
      } else {
        await jobs.update(job.id,
            status: JobStatus.done,
            stage: 'Done',
            progress: 100,
            finished: true,
            title: r.track?.title,
            artist: r.track?.artistName);
      }
      if (note != null) await jobs.appendLog(job.id, '\n$note\n');
      _finishedSinceIdle++;
      _events.add(DownloadEvent('finished', await jobs.byId(job.id), message: note));
    } on DownloadFailure catch (f) {
      if (f.cancelled || a.cancelRequested) {
        await jobs.update(job.id, status: JobStatus.cancelled, stage: 'Cancelled', finished: true);
      } else {
        await jobs.update(job.id, status: JobStatus.failed, stage: 'Failed', error: '${f.error.message}${f.error.hint == null ? '' : '\n${f.error.hint}'}', finished: true);
        await jobs.appendLog(job.id, f.raw);
        _failedSinceIdle++;
        _events.add(DownloadEvent('failed', await jobs.byId(job.id), message: f.error.message));
      }
    } on Object catch (e, st) {
      if (kDebugMode) debugPrint('download job ${job.id} crashed: $e\n$st');
      await jobs.update(job.id, status: JobStatus.failed, stage: 'Failed', error: DownloadError.classify(e.toString()).message, finished: true);
      _failedSinceIdle++;
      _events.add(DownloadEvent('failed', await jobs.byId(job.id), message: '$e'));
    } finally {
      _active.remove(job.id);
      try {
        if (workDir.existsSync()) workDir.deleteSync(recursive: true);
      } on FileSystemException {
        // cleaned on next start
      }
      notifyListeners();
      await pump();
      if (_active.isEmpty && (await jobs.queued()).isEmpty) await _onIdle();
    }
  }

  Future<void> _onIdle() async {
    await _updateForeground();
    final done = _finishedSinceIdle, failed = _failedSinceIdle;
    _finishedSinceIdle = 0;
    _failedSinceIdle = 0;
    if (done + failed == 0) return;
    _events.add(DownloadEvent('allDone', null, message: '$done finished, $failed failed'));
    try {
      await bridges.system.notify(
        id: 2001,
        title: failed == 0 ? 'Downloads finished' : 'Downloads finished with errors',
        body: failed == 0 ? '$done ${done == 1 ? 'track' : 'tracks'} added to your library' : '$done added, $failed failed',
      );
    } on PlatformFailure {
      // notifications unavailable
    }
  }

  Future<void> _updateForeground() async {
    if (!isAndroid) return;
    try {
      if (_active.isEmpty) {
        await bridges.ytDlp.setForeground(active: false);
        return;
      }
      final avg = _active.values.map((e) => e.progress).fold<double>(0, (a, b) => a + b) / _active.length;
      final queued = (await jobs.queued()).length;
      final first = _active.values.first.job;
      await bridges.ytDlp.setForeground(
        active: true,
        title: _active.length == 1 ? (first.title ?? 'Downloading') : 'Downloading ${_active.length} tracks',
        text: queued > 0 ? '$queued more queued' : 'Working...',
        progress: avg.round(),
      );
    } on PlatformFailure {
      // the service is best-effort
    }
  }
}
