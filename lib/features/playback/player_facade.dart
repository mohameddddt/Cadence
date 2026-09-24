import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart' show AndroidEqualizerParameters;

import '../../core/models/track.dart';
import '../sources/podcast_radio.dart';
import '../sources/source_provider.dart';
import 'audio_handler.dart';
import 'media_items.dart';
import 'sleep_timer.dart';

/// Everything the UI needs from playback, without exposing the MediaSession machinery.
/// Tests substitute a fake.
abstract class PlayerFacade {
  Stream<MediaItem?> get currentItem;
  MediaItem? get current;
  Stream<PlaybackState> get state;
  PlaybackState get playbackState;
  Stream<List<MediaItem>> get queue;
  List<MediaItem> get items;
  int get currentIndex;
  Stream<Duration> get position;
  Stream<SleepTimerState> get sleepState;
  SleepTimerState get sleep;
  Stream<String> get errors;

  bool get playing;

  Future<void> playTracks(List<Track> tracks, {int index = 0, bool shuffle = false});
  Future<void> enqueue(List<Track> tracks);
  Future<void> playNext(List<Track> tracks);
  Future<void> playRemote(RemoteTrack track);
  Future<void> enqueueRemote(RemoteTrack track);
  Future<void> playStation(RadioStation station);
  Future<void> playEpisodes(List<PodcastEpisode> episodes, {int index = 0});
  Future<void> playMediaItems(List<MediaItem> items, {int index = 0});

  Future<void> play();
  Future<void> pause();
  Future<void> toggle();
  Future<void> next();
  Future<void> previous();
  Future<void> seek(Duration position);
  Future<void> skipTo(int index);
  Future<void> removeAt(int index);
  Future<void> move(int oldIndex, int newIndex);
  Future<void> clear();
  Future<void> stop();

  bool get shuffle;
  AudioServiceRepeatMode get repeat;
  Future<void> setShuffle(bool on);
  Future<void> cycleRepeat();
  Future<void> setSpeed(double speed);

  void startSleepMinutes(int minutes);
  void startSleepEndOfTrack();
  void extendSleep(Duration by);
  void cancelSleep();

  Future<AndroidEqualizerParameters?> equalizerParameters();
}

/// The real thing, backed by [MusicAudioHandler].
class HandlerPlayerFacade implements PlayerFacade {
  HandlerPlayerFacade(this.handler);

  final MusicAudioHandler handler;

  @override
  Stream<MediaItem?> get currentItem => handler.mediaItem;

  @override
  MediaItem? get current => handler.mediaItem.valueOrNull;

  @override
  Stream<PlaybackState> get state => handler.playbackState;

  @override
  PlaybackState get playbackState => handler.playbackState.value;

  @override
  Stream<List<MediaItem>> get queue => handler.queue;

  @override
  List<MediaItem> get items => handler.items;

  @override
  int get currentIndex => handler.currentIndex;

  @override
  Stream<Duration> get position => AudioService.position;

  @override
  Stream<SleepTimerState> get sleepState => handler.sleepTimer.stream;

  @override
  SleepTimerState get sleep => handler.sleepTimer.state;

  @override
  Stream<String> get errors => handler.errors;

  @override
  bool get playing => handler.playbackState.value.playing;

  @override
  Future<void> playTracks(List<Track> tracks, {int index = 0, bool shuffle = false}) =>
      handler.setQueue([for (final t in tracks) trackToMediaItem(t)], index: index, shuffle: shuffle);

  @override
  Future<void> enqueue(List<Track> tracks) => handler.addQueueItems([for (final t in tracks) trackToMediaItem(t)]);

  @override
  Future<void> playNext(List<Track> tracks) => handler.playNext([for (final t in tracks) trackToMediaItem(t)]);

  @override
  Future<void> playRemote(RemoteTrack track) async {
    final item = await handler.resolveRemote(track.toMediaItem());
    await handler.setQueue([item]);
  }

  @override
  Future<void> enqueueRemote(RemoteTrack track) async => handler.addQueueItem(await handler.resolveRemote(track.toMediaItem()));

  @override
  Future<void> playStation(RadioStation station) => handler.setQueue([station.toMediaItem()]);

  @override
  Future<void> playEpisodes(List<PodcastEpisode> episodes, {int index = 0}) =>
      handler.setQueue([for (final e in episodes) e.toMediaItem()], index: index);

  @override
  Future<void> playMediaItems(List<MediaItem> items, {int index = 0}) => handler.setQueue(items, index: index);

  @override
  Future<void> play() => handler.play();

  @override
  Future<void> pause() => handler.pause();

  @override
  Future<void> toggle() => playing ? handler.pause() : handler.play();

  @override
  Future<void> next() => handler.skipToNext();

  @override
  Future<void> previous() => handler.skipToPrevious();

  @override
  Future<void> seek(Duration position) => handler.seek(position);

  @override
  Future<void> skipTo(int index) => handler.skipToQueueItem(index);

  @override
  Future<void> removeAt(int index) => handler.removeQueueItemAt(index);

  @override
  Future<void> move(int oldIndex, int newIndex) => handler.moveQueueItem(oldIndex, newIndex);

  @override
  Future<void> clear() => handler.clearQueue();

  @override
  Future<void> stop() => handler.stop();

  @override
  bool get shuffle => handler.playbackState.value.shuffleMode != AudioServiceShuffleMode.none;

  @override
  AudioServiceRepeatMode get repeat => handler.playbackState.value.repeatMode;

  @override
  Future<void> setShuffle(bool on) => handler.setShuffleMode(on ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none);

  @override
  Future<void> cycleRepeat() => handler.setRepeatMode(switch (repeat) {
        AudioServiceRepeatMode.none => AudioServiceRepeatMode.all,
        AudioServiceRepeatMode.all => AudioServiceRepeatMode.one,
        _ => AudioServiceRepeatMode.none,
      });

  @override
  Future<void> setSpeed(double speed) => handler.setSpeed(speed);

  @override
  void startSleepMinutes(int minutes) => handler.sleepTimer.startMinutes(minutes);

  @override
  void startSleepEndOfTrack() => handler.sleepTimer.startEndOfTrack();

  @override
  void extendSleep(Duration by) => handler.sleepTimer.extend(by);

  @override
  void cancelSleep() => handler.sleepTimer.cancel();

  @override
  Future<AndroidEqualizerParameters?> equalizerParameters() => handler.equalizerParameters();
}
