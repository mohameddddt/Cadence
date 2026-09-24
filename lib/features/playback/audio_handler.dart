import 'dart:async';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';

import '../../core/library/library_repository.dart';
import '../../core/library/smart_rules.dart';
import '../../core/models/track.dart';
import '../../core/settings/settings_store.dart';
import 'media_items.dart';
import 'play_tracker.dart';
import 'replay_gain.dart';
import 'sleep_timer.dart';

/// Finds artwork (file URI) for the item that is about to be shown in the notification.
abstract class ArtworkResolver {
  Future<Uri?> artFor(MediaItem item);
}

/// Turns a page URL (YouTube, SoundCloud...) into a directly playable stream URL.
abstract class StreamResolver {
  Future<Uri> resolveStream(String pageUrl);
}

/// Owns the ExoPlayer instance and mirrors it into a MediaSession (lock screen, Bluetooth,
/// Android Auto, Wear). Everything the UI needs goes through this class.
class MusicAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  MusicAudioHandler({
    required this.repo,
    required this.settings,
    this.artwork,
    this.streams,
    this.onPlayCounted,
    this.onNowPlaying,
    AudioPlayer? testPlayer,
  }) {
    equalizer = AndroidEqualizer();
    loudness = AndroidLoudnessEnhancer();
    player = testPlayer ??
        AudioPlayer(
          // Interruptions are handled below so the ducking / pause settings apply.
          handleInterruptions: false,
          audioPipeline: AudioPipeline(androidAudioEffects: [loudness, equalizer]),
        );
    _tracker = PlayTracker(
      onNowPlaying: (_) {
        final item = mediaItem.valueOrNull;
        if (item != null) onNowPlaying?.call(item);
      },
      onCounted: (key, {required scrobbleEligible}) {
        final item = mediaItem.valueOrNull;
        if (item != null) onPlayCounted?.call(item, scrobbleEligible);
      },
    );
    _sleep = SleepTimer(onExpire: () => pause());
    _init();
  }

  final LibraryRepository repo;
  final SettingsStore settings;
  final ArtworkResolver? artwork;
  final StreamResolver? streams;

  /// Fired once a listen counts (>= 50 % or 4 min): play statistics and scrobbling.
  final void Function(MediaItem item, bool scrobbleEligible)? onPlayCounted;

  /// Fired when a track starts (Last.fm "now playing").
  final void Function(MediaItem item)? onNowPlaying;

  late final AndroidEqualizer equalizer;
  late final AndroidLoudnessEnhancer loudness;
  late final AudioPlayer player;
  late final PlayTracker _tracker;
  late final SleepTimer _sleep;

  SleepTimer get sleepTimer => _sleep;

  final StreamController<String> _errors = StreamController<String>.broadcast();

  /// Human readable playback problems for a snackbar.
  Stream<String> get errors => _errors.stream;

  List<MediaItem> _items = [];
  int _index = 0;

  // Volume is the product of independent factors.
  double _rgVolume = 1;
  double _fade = 1;
  double _duck = 1;
  bool _pausedByInterruption = false;
  bool _pausedByNoisy = false;
  bool _autoAdvanced = false;
  bool _restoring = false;
  final Set<String> _recovering = {};
  Timer? _persistTimer;
  DateTime _lastPositionSave = DateTime.fromMillisecondsSinceEpoch(0);
  final List<StreamSubscription<dynamic>> _subs = [];

  // ------------------------------------------------------------------ setup

  Future<void> _init() async {
    _subs.add(player.playbackEventStream.map(_transform).listen(playbackState.add, onError: (Object e) {
      _errors.add('Playback error: $e');
    }));
    _subs.add(player.currentIndexStream.listen(_onIndexChanged));
    _subs.add(player.durationStream.listen(_onDuration));
    _subs.add(player.positionDiscontinuityStream.listen(_onDiscontinuity));
    _subs.add(player.processingStateStream.listen((s) {
      if (s == ProcessingState.completed) _sleep.trackFinished();
    }));
    _subs.add(player.errorStream.listen(_onPlayerError));
    _subs.add(player.icyMetadataStream.listen(_onIcy));
    _subs.add(Rx.combineLatest2<Duration, bool, void>(
      player.positionStream.throttleTime(const Duration(milliseconds: 500), trailing: true),
      player.playingStream,
      (pos, playing) => _onTick(pos, playing),
    ).listen((_) {}));

    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      _subs.add(session.interruptionEventStream.listen(_onInterruption));
      _subs.add(session.becomingNoisyEventStream.listen((_) {
        if (settings.pauseWhenNoisy && player.playing) {
          _pausedByNoisy = true;
          pause();
        }
      }));
      _subs.add(session.devicesChangedEventStream.listen((e) {
        // ignore: experimental_member_use
        final connected = e.devicesAdded.any((d) => d.isOutput && (d.type == AudioDeviceType.wiredHeadphones || d.type == AudioDeviceType.wiredHeadset || d.type == AudioDeviceType.bluetoothA2dp));
        if (connected && _pausedByNoisy && settings.resumeOnHeadphones) {
          _pausedByNoisy = false;
          play();
        }
      }));
    } catch (_) {
      // No audio session in unit tests / desktop.
    }

    settings.addListener(_onSettingsChanged);
    _applyEqualizerSettings();
  }

  // ---------------------------------------------------------------- mapping

  PlaybackState _transform(PlaybackEvent e) {
    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (player.playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
        MediaControl.stop,
      ],
      systemActions: const {MediaAction.seek, MediaAction.seekForward, MediaAction.seekBackward},
      androidCompactActionIndices: const [0, 1, 2],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[player.processingState]!,
      playing: player.playing,
      updatePosition: player.position,
      bufferedPosition: player.bufferedPosition,
      speed: player.speed,
      queueIndex: e.currentIndex,
      repeatMode: const {
        LoopMode.off: AudioServiceRepeatMode.none,
        LoopMode.one: AudioServiceRepeatMode.one,
        LoopMode.all: AudioServiceRepeatMode.all,
      }[player.loopMode]!,
      shuffleMode: player.shuffleModeEnabled ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none,
    );
  }

  AudioSource _sourceFor(MediaItem item) => AudioSource.uri(Uri.parse(item.id), tag: item);

  // ------------------------------------------------------------------ queue

  List<MediaItem> get items => List.unmodifiable(_items);
  int get currentIndex => _index;

  /// Replaces the queue and (optionally) starts playing.
  Future<void> setQueue(
    List<MediaItem> items, {
    int index = 0,
    Duration position = Duration.zero,
    bool play = true,
    bool shuffle = false,
  }) async {
    if (items.isEmpty) {
      await clearQueue();
      return;
    }
    final safeIndex = index.clamp(0, items.length - 1);
    _items = List.of(items);
    _index = safeIndex;
    queue.add(_items);
    mediaItem.add(_items[safeIndex]);
    try {
      await player.setAudioSources(
        _items.map(_sourceFor).toList(),
        initialIndex: safeIndex,
        initialPosition: position,
        preload: play,
      );
      if (shuffle) {
        await player.setShuffleModeEnabled(true);
        await player.shuffle();
        await settings.setShuffleOn(true);
      }
    } on PlayerInterruptedException {
      return; // a newer setQueue call won
    } catch (e) {
      _errors.add('Cannot play: $e');
      return;
    }
    _schedulePersist();
    if (play) unawaited(player.play());
  }

  Future<void> clearQueue() async {
    _items = [];
    _index = 0;
    queue.add(_items);
    await player.stop();
    await player.setAudioSources(const [], preload: false);
    mediaItem.add(null);
    _schedulePersist();
  }

  @override
  Future<void> addQueueItem(MediaItem mediaItem) async {
    if (_items.isEmpty) return setQueue([mediaItem]);
    _items.add(mediaItem);
    await player.addAudioSource(_sourceFor(mediaItem));
    queue.add(_items);
    _schedulePersist();
  }

  @override
  Future<void> addQueueItems(List<MediaItem> mediaItems) async {
    if (mediaItems.isEmpty) return;
    if (_items.isEmpty) return setQueue(mediaItems);
    _items.addAll(mediaItems);
    await player.addAudioSources(mediaItems.map(_sourceFor).toList());
    queue.add(_items);
    _schedulePersist();
  }

  @override
  Future<void> insertQueueItem(int index, MediaItem mediaItem) async {
    if (_items.isEmpty) return setQueue([mediaItem]);
    final at = index.clamp(0, _items.length);
    _items.insert(at, mediaItem);
    await player.insertAudioSource(at, _sourceFor(mediaItem));
    if (at <= _index) _index++;
    queue.add(_items);
    _schedulePersist();
  }

  /// "Play next": right after the current item.
  Future<void> playNext(List<MediaItem> mediaItems) async {
    if (_items.isEmpty) return setQueue(mediaItems, play: false);
    var at = _index + 1;
    for (final m in mediaItems) {
      _items.insert(at, m);
      await player.insertAudioSource(at, _sourceFor(m));
      at++;
    }
    queue.add(_items);
    _schedulePersist();
  }

  @override
  Future<void> removeQueueItemAt(int index) async {
    if (index < 0 || index >= _items.length) return;
    _items.removeAt(index);
    await player.removeAudioSourceAt(index);
    if (index < _index) _index--;
    queue.add(_items);
    if (_items.isEmpty) mediaItem.add(null);
    _schedulePersist();
  }

  Future<void> moveQueueItem(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= _items.length) return;
    final target = newIndex.clamp(0, _items.length - 1);
    if (oldIndex == target) return;
    final item = _items.removeAt(oldIndex);
    _items.insert(target, item);
    await player.moveAudioSource(oldIndex, target);
    queue.add(_items);
    _schedulePersist();
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= _items.length) return;
    await player.seek(Duration.zero, index: index);
    _autoAdvanced = false;
    unawaited(player.play());
  }

  /// Replaces one queue entry in place (artwork arrived, stream URL refreshed).
  Future<void> _replaceItem(int index, MediaItem item, {bool reload = false}) async {
    if (index < 0 || index >= _items.length) return;
    _items[index] = item;
    queue.add(_items);
    if (index == _index) mediaItem.add(item);
    if (reload) {
      final pos = player.position;
      final wasPlaying = player.playing;
      await player.removeAudioSourceAt(index);
      await player.insertAudioSource(index, _sourceFor(item));
      await player.seek(pos, index: index);
      if (wasPlaying) unawaited(player.play());
    }
  }

  // --------------------------------------------------------------- transport

  @override
  Future<void> play() async {
    _pausedByInterruption = false;
    _pausedByNoisy = false;
    if (_items.isNotEmpty && player.processingState == ProcessingState.idle) {
      try {
        await player.load();
      } catch (e) {
        _errors.add('Cannot play: $e');
        return;
      }
    }
    if (player.processingState == ProcessingState.completed) {
      await player.seek(Duration.zero, index: 0);
    }
    await player.play();
  }

  @override
  Future<void> pause() async {
    await player.pause();
    await _savePosition(force: true);
  }

  @override
  Future<void> stop() async {
    await player.stop();
    await _savePosition(force: true);
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) => player.seek(position);

  @override
  Future<void> skipToNext() async {
    _autoAdvanced = false;
    if (_items.isEmpty) return;
    if (player.hasNext) await player.seekToNext();
  }

  @override
  Future<void> skipToPrevious() async {
    _autoAdvanced = false;
    if (_items.isEmpty) return;
    if (player.position > const Duration(seconds: 3) || !player.hasPrevious) {
      await player.seek(Duration.zero);
    } else {
      await player.seekToPrevious();
    }
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    await player.setLoopMode(const {
      AudioServiceRepeatMode.none: LoopMode.off,
      AudioServiceRepeatMode.one: LoopMode.one,
      AudioServiceRepeatMode.all: LoopMode.all,
      AudioServiceRepeatMode.group: LoopMode.all,
    }[repeatMode]!);
    await settings.setRepeatMode(const {LoopMode.off: 0, LoopMode.one: 1, LoopMode.all: 2}[player.loopMode]!);
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    final on = shuffleMode != AudioServiceShuffleMode.none;
    if (on) await player.shuffle();
    await player.setShuffleModeEnabled(on);
    await settings.setShuffleOn(on);
  }

  @override
  Future<void> setSpeed(double speed) => player.setSpeed(speed);

  /// Pitch-preserving speed change plus optional skip-silence.
  Future<void> setSkipSilence(bool enabled) => player.setSkipSilenceEnabled(enabled);

  // -------------------------------------------------------------- volume mix

  void _applyVolume() {
    final v = (_rgVolume * _fade * _duck).clamp(0.0, 1.0);
    player.setVolume(v);
  }

  Future<void> _applyReplayGain(MediaItem? item) async {
    final r = item == null
        ? ReplayGainResult.neutral
        : ReplayGain.compute(
            mode: settings.replayGainMode,
            trackGain: item.rgTrack,
            albumGain: item.rgAlbum,
            preampDb: settings.replayGainPreamp,
          );
    _rgVolume = r.volume;
    _applyVolume();
    try {
      final boost = math.max(r.boostDb, settings.loudnessBoostDb);
      await loudness.setTargetGain(boost);
      await loudness.setEnabled(boost > 0);
    } catch (_) {
      // Not on Android, or the audio session is not ready yet.
    }
  }

  void _onSettingsChanged() {
    _applyReplayGain(mediaItem.valueOrNull);
    _applyEqualizerSettings();
  }

  // ----------------------------------------------------------- equalizer

  Future<AndroidEqualizerParameters?> equalizerParameters() async {
    try {
      return await equalizer.parameters;
    } catch (_) {
      return null;
    }
  }

  Future<void> _applyEqualizerSettings() async {
    try {
      await equalizer.setEnabled(settings.equalizerEnabled);
      final gains = settings.equalizerGains;
      if (gains.isEmpty || !settings.equalizerEnabled) return;
      final params = await equalizer.parameters;
      for (var i = 0; i < params.bands.length && i < gains.length; i++) {
        await params.bands[i].setGain(gains[i].clamp(params.minDecibels, params.maxDecibels));
      }
    } catch (_) {}
  }

  // ------------------------------------------------------------- events

  void _onIndexChanged(int? index) {
    if (index == null || index < 0 || index >= _items.length) return;
    _index = index;
    final item = _items[index];
    mediaItem.add(item);
    _tracker.trackChanged(item.playKey, item.duration?.inMilliseconds ?? 0);
    _applyReplayGain(item);
    _schedulePersist();
    _fade = _autoAdvanced && settings.crossfadeSeconds > 0 ? 0 : 1;
    _autoAdvanced = false;
    _applyVolume();
    // Artwork can take a moment (embedded image extraction); update when ready.
    final art = artwork;
    if (art != null && item.artUri == null) {
      art.artFor(item).then((uri) {
        if (uri != null && index < _items.length && _items[index].id == item.id) {
          _replaceItem(index, item.copyWith(artUri: uri));
        }
      }).catchError((Object _) {});
    }
  }

  void _onDuration(Duration? d) {
    final item = mediaItem.valueOrNull;
    if (d == null || item == null) return;
    _tracker.durationKnown(d.inMilliseconds);
    if (item.duration != d && _index < _items.length) {
      final updated = item.copyWith(duration: d);
      _items[_index] = updated;
      queue.add(_items);
      mediaItem.add(updated);
    }
  }

  void _onDiscontinuity(PositionDiscontinuity e) {
    if (e.reason == PositionDiscontinuityReason.autoAdvance) {
      _autoAdvanced = true;
      if (_sleep.state.mode == SleepMode.endOfTrack) {
        // The next track already started; stop and rewind it.
        player.pause();
        player.seek(Duration.zero);
        _sleep.trackFinished();
      }
    }
  }

  void _onTick(Duration position, bool playing) {
    _tracker.tick(position.inMilliseconds, playing: playing);
    _updateFade(position);
    _savePosition();
  }

  void _updateFade(Duration position) {
    final seconds = settings.crossfadeSeconds;
    final duration = player.duration;
    if (seconds <= 0 || duration == null || duration.inSeconds < seconds * 3) {
      if (_fade != 1) {
        _fade = 1;
        _applyVolume();
      }
      return;
    }
    final window = Duration(seconds: seconds).inMilliseconds;
    final fadeIn = (position.inMilliseconds / window).clamp(0.0, 1.0);
    final fadeOut = ((duration - position).inMilliseconds / window).clamp(0.0, 1.0);
    final next = math.min(fadeIn, fadeOut);
    // Manual skips restart at full volume (only auto-advance fades in, handled in _onIndexChanged).
    final target = _autoAdvanced || fadeIn >= 1 || position.inMilliseconds > window ? next : math.max(next, 1.0);
    if ((target - _fade).abs() > 0.02) {
      _fade = target;
      _applyVolume();
    }
  }

  void _onInterruption(AudioInterruptionEvent e) {
    if (e.begin) {
      switch (e.type) {
        case AudioInterruptionType.duck:
          if (settings.duckForInterruptions) {
            _duck = 0.35;
            _applyVolume();
          } else if (player.playing) {
            _pausedByInterruption = true;
            pause();
          }
        case AudioInterruptionType.pause:
        case AudioInterruptionType.unknown:
          if (player.playing) {
            _pausedByInterruption = true;
            pause();
          }
      }
    } else {
      switch (e.type) {
        case AudioInterruptionType.duck:
          _duck = 1;
          _applyVolume();
        case AudioInterruptionType.pause:
        case AudioInterruptionType.unknown:
          if (_pausedByInterruption) {
            _pausedByInterruption = false;
            play();
          }
      }
    }
  }

  /// Live radio: show "Artist - Title" from ICY metadata in the notification.
  void _onIcy(IcyMetadata? icy) {
    final item = mediaItem.valueOrNull;
    final title = icy?.info?.title;
    if (item == null || title == null || !item.isRadio || title.isEmpty) return;
    final parts = title.split(' - ');
    final updated = item.copyWith(
      title: parts.length > 1 ? parts.sublist(1).join(' - ') : title,
      artist: parts.length > 1 ? parts.first : (item.extras?['station'] as String?) ?? item.artist,
    );
    mediaItem.add(updated);
  }

  // ------------------------------------------------- remote stream recovery

  Future<void> _onPlayerError(PlayerException e) async {
    final item = mediaItem.valueOrNull;
    if (item != null && item.resolveUrl != null && streams != null && _recovering.add(item.id)) {
      // Signed stream URLs expire (YouTube ~6 h) and answer 403: resolve a fresh one.
      try {
        final fresh = await streams!.resolveStream(item.resolveUrl!);
        final updated = item.copyWith(
          id: fresh.toString(),
          extras: {...?item.extras, MediaExtras.resolvedAt: DateTime.now().millisecondsSinceEpoch},
        );
        await _replaceItem(_index, updated, reload: true);
        return;
      } catch (_) {
        // fall through to the error message
      } finally {
        _recovering.remove(item.id);
      }
    }
    _errors.add('Playback error: ${e.message ?? e.code}');
    if (player.hasNext) {
      await player.seekToNext();
      unawaited(player.play());
    }
  }

  /// Resolve a page URL into a playable queue item right now.
  Future<MediaItem> resolveRemote(MediaItem item) async {
    final url = item.resolveUrl;
    if (url == null || streams == null) return item;
    final stream = await streams!.resolveStream(url);
    return item.copyWith(
      id: stream.toString(),
      extras: {...?item.extras, MediaExtras.remote: true, MediaExtras.resolvedAt: DateTime.now().millisecondsSinceEpoch},
    );
  }

  // -------------------------------------------------------------- persistence

  void _schedulePersist() {
    if (_restoring) return;
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 600), () async {
      await repo.saveQueue([for (final m in _items) mediaItemToJson(m)]);
      await _savePosition(force: true);
    });
  }

  Future<void> _savePosition({bool force = false}) async {
    final now = DateTime.now();
    if (!force && now.difference(_lastPositionSave) < const Duration(seconds: 5)) return;
    _lastPositionSave = now;
    await settings.saveQueuePosition(_index, player.position.inMilliseconds);
  }

  /// Rebuilds the previous session's queue (paused) after a restart.
  Future<void> restoreQueue() async {
    _restoring = true;
    try {
      final saved = await repo.loadQueue();
      if (saved.isEmpty) return;
      final items = saved.map(mediaItemFromJson).toList();
      final index = settings.queueIndex.clamp(0, items.length - 1);
      await setQueue(items, index: index, position: Duration(milliseconds: settings.queuePositionMs), play: false);
      await player.setLoopMode(const [LoopMode.off, LoopMode.one, LoopMode.all][settings.repeatMode.clamp(0, 2)]);
      if (settings.shuffleOn) await player.setShuffleModeEnabled(true);
    } finally {
      _restoring = false;
    }
  }

  // ------------------------------------------------ Android Auto / browsing

  static const String _recent = 'recent';
  static const String _albums = 'albums';
  static const String _artists = 'artists';
  static const String _playlists = 'playlists';
  static const String _songs = 'songs';

  @override
  Future<List<MediaItem>> getChildren(String parentMediaId, [Map<String, dynamic>? options]) async {
    switch (parentMediaId) {
      case AudioService.browsableRootId:
        return const [
          MediaItem(id: _recent, title: 'Recently added', playable: false),
          MediaItem(id: _albums, title: 'Albums', playable: false),
          MediaItem(id: _artists, title: 'Artists', playable: false),
          MediaItem(id: _playlists, title: 'Playlists', playable: false),
          MediaItem(id: _songs, title: 'All songs', playable: false),
        ];
      case _recent:
        return (await repo.recentlyAdded(limit: 50)).map((t) => _browseTrack(t, 'recent')).toList();
      case _songs:
        return (await repo.tracks(limit: 300)).map((t) => _browseTrack(t, 'songs')).toList();
      case _albums:
        return [
          for (final a in await repo.albums())
            MediaItem(id: 'album:${a.id}', title: a.title, artist: a.displayArtist, playable: false, artUri: a.coverPath == null ? null : Uri.file(a.coverPath!)),
        ];
      case _artists:
        return [for (final a in await repo.artists()) MediaItem(id: 'artist:${a.id}', title: a.name, playable: false)];
      case _playlists:
        return [for (final p in await repo.playlists()) MediaItem(id: 'playlist:${p.id}', title: p.name, playable: false)];
    }
    final parts = parentMediaId.split(':');
    if (parts.length == 2) {
      final id = int.tryParse(parts[1]);
      if (id == null) return const [];
      switch (parts[0]) {
        case 'album':
          return (await repo.tracks(albumId: id, sort: TrackSort.album)).map((t) => _browseTrack(t, 'album:$id')).toList();
        case 'artist':
          return (await repo.tracks(artistId: id, sort: TrackSort.album)).map((t) => _browseTrack(t, 'artist:$id')).toList();
        case 'playlist':
          final p = await repo.playlistById(id);
          if (p == null) return const [];
          return (await repo.playlistTracks(p)).map((t) => _browseTrack(t, 'playlist:$id')).toList();
      }
    }
    return const [];
  }

  /// Browse ids look like `track:ID@context` so tapping a song can queue its siblings.
  MediaItem _browseTrack(Track t, String context) => MediaItem(
        id: 'track:${t.id}@$context',
        title: t.title,
        artist: t.displayArtist,
        album: t.albumTitle,
        duration: t.durationMs > 0 ? t.duration : null,
        playable: true,
      );

  @override
  Future<MediaItem?> getMediaItem(String mediaId) async {
    final t = await _trackFromBrowseId(mediaId);
    return t == null ? null : trackToMediaItem(t);
  }

  Future<Track?> _trackFromBrowseId(String mediaId) async {
    if (!mediaId.startsWith('track:')) return null;
    final id = int.tryParse(mediaId.substring(6).split('@').first);
    return id == null ? null : repo.trackById(id);
  }

  @override
  Future<void> playFromMediaId(String mediaId, [Map<String, dynamic>? extras]) async {
    if (!mediaId.startsWith('track:')) return;
    final rest = mediaId.substring(6).split('@');
    final id = int.tryParse(rest.first);
    if (id == null) return;
    final ctx = rest.length > 1 ? rest[1] : 'songs';
    List<Track> list;
    final parts = ctx.split(':');
    if (parts.length == 2 && int.tryParse(parts[1]) != null) {
      final cid = int.parse(parts[1]);
      list = switch (parts[0]) {
        'album' => await repo.tracks(albumId: cid, sort: TrackSort.album),
        'artist' => await repo.tracks(artistId: cid, sort: TrackSort.album),
        'playlist' => await repo.playlistTracks((await repo.playlistById(cid))!),
        _ => await repo.tracks(limit: 300),
      };
    } else if (ctx == 'recent') {
      list = await repo.recentlyAdded(limit: 50);
    } else {
      list = await repo.tracks(limit: 300);
    }
    final idx = list.indexWhere((t) => t.id == id);
    if (idx < 0) {
      final t = await repo.trackById(id);
      if (t != null) await setQueue([trackToMediaItem(t)]);
      return;
    }
    await setQueue(list.map((t) => trackToMediaItem(t)).toList(), index: idx);
  }

  /// "Hey Google, play QUERY" and Android Auto search.
  @override
  Future<void> playFromSearch(String query, [Map<String, dynamic>? extras]) async {
    final results = await repo.searchTracks(query, limit: 50);
    if (results.isNotEmpty) await setQueue(results.map((t) => trackToMediaItem(t)).toList());
  }

  @override
  Future<List<MediaItem>> search(String query, [Map<String, dynamic>? extras]) async =>
      (await repo.searchTracks(query, limit: 30)).map((t) => _browseTrack(t, 'songs')).toList();

  @override
  Future<void> onTaskRemoved() async {
    if (!player.playing) await stop();
  }

  Future<void> dispose() async {
    settings.removeListener(_onSettingsChanged);
    _persistTimer?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    _sleep.dispose();
    await _errors.close();
    await player.dispose();
  }
}
