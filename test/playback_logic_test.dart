import 'package:audio_service/audio_service.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/core/models/track.dart';
import 'package:musicplayer/core/settings/settings_store.dart';
import 'package:musicplayer/features/playback/media_items.dart';
import 'package:musicplayer/features/playback/play_tracker.dart';
import 'package:musicplayer/features/playback/replay_gain.dart';
import 'package:musicplayer/features/playback/sleep_timer.dart';

void main() {
  group('ReplayGain', () {
    test('off leaves the volume alone', () {
      final r = ReplayGain.compute(mode: ReplayGainMode.off, trackGain: -8);
      expect(r.volume, 1);
      expect(r.boostDb, 0);
    });

    test('negative gain becomes attenuation (-6.02 dB = half amplitude)', () {
      final r = ReplayGain.compute(mode: ReplayGainMode.track, trackGain: -6.0206);
      expect(r.volume, closeTo(0.5, 0.001));
      expect(r.boostDb, 0);
    });

    test('positive gain uses the loudness enhancer, capped', () {
      final r = ReplayGain.compute(mode: ReplayGainMode.track, trackGain: 4.5);
      expect(r.volume, 1);
      expect(r.boostDb, 4.5);
      expect(ReplayGain.compute(mode: ReplayGainMode.track, trackGain: 30).boostDb, ReplayGain.maxBoostDb);
    });

    test('album mode prefers album gain and falls back to track gain', () {
      expect(ReplayGain.compute(mode: ReplayGainMode.album, trackGain: -10, albumGain: -3).volume, closeTo(0.708, 0.001));
      expect(ReplayGain.compute(mode: ReplayGainMode.album, trackGain: -6.0206).volume, closeTo(0.5, 0.001));
      expect(ReplayGain.compute(mode: ReplayGainMode.track, trackGain: null, albumGain: -6.0206).volume, closeTo(0.5, 0.001));
    });

    test('preamp shifts the result; untagged tracks stay untouched without preamp', () {
      expect(ReplayGain.compute(mode: ReplayGainMode.track, trackGain: -6.0206, preampDb: 6.0206).volume, closeTo(1, 0.001));
      expect(ReplayGain.compute(mode: ReplayGainMode.track).volume, 1);
      expect(ReplayGain.compute(mode: ReplayGainMode.track, preampDb: -6.0206).volume, closeTo(0.5, 0.001));
    });
  });

  group('PlayTracker', () {
    late List<String> events;
    late PlayTracker tracker;

    setUp(() {
      events = [];
      tracker = PlayTracker(
        onNowPlaying: (k) => events.add('now:$k'),
        onCounted: (k, {required scrobbleEligible}) => events.add('count:$k:${scrobbleEligible ? 'scrobble' : 'short'}'),
      );
    });

    void playFor(int seconds, {int from = 0, int step = 500}) {
      for (var ms = from; ms < from + seconds * 1000; ms += step) {
        tracker.tick(ms, playing: true);
      }
    }

    test('counts once at 50 % of a 3-minute track', () {
      tracker.trackChanged('a', 180000);
      playFor(89);
      expect(events, ['now:a']);
      playFor(3, from: 89000);
      expect(events, ['now:a', 'count:a:scrobble']);
      playFor(60, from: 92000);
      expect(events.where((e) => e.startsWith('count')).length, 1);
    });

    test('long tracks count at 4 minutes, not 50 %', () {
      tracker.trackChanged('long', 1200000);
      playFor(239);
      expect(events.any((e) => e.startsWith('count')), isFalse);
      playFor(3, from: 239000);
      expect(events.any((e) => e.startsWith('count')), isTrue);
    });

    test('seeking forward does not earn listening time', () {
      tracker.trackChanged('a', 180000);
      playFor(10);
      tracker.tick(150000, playing: true); // jump
      tracker.tick(150500, playing: true);
      expect(events.any((e) => e.startsWith('count')), isFalse);
      expect(tracker.listenedMs, lessThan(12000));
    });

    test('paused time does not count', () {
      tracker.trackChanged('a', 60000);
      for (var ms = 0; ms < 40000; ms += 500) {
        tracker.tick(ms, playing: false);
      }
      expect(events.any((e) => e.startsWith('count')), isFalse);
    });

    test('tracks under 30 s count for statistics but are not scrobble eligible', () {
      tracker.trackChanged('short', 20000);
      playFor(11);
      expect(events, contains('count:short:short'));
    });

    test('a new track resets progress', () {
      tracker.trackChanged('a', 60000);
      playFor(20);
      tracker.trackChanged('b', 60000);
      playFor(20);
      expect(events.any((e) => e.startsWith('count')), isFalse);
      playFor(11, from: 20000);
      expect(events, contains('count:b:scrobble'));
    });

    test('repeat-one: restarting after the listen counted starts a new listen', () {
      tracker.trackChanged('a', 40000);
      playFor(21);
      expect(events.where((e) => e.startsWith('count')).length, 1);
      tracker.tick(300, playing: true); // wrapped around
      playFor(21, from: 500);
      expect(events.where((e) => e.startsWith('count')).length, 2);
      expect(events.where((e) => e.startsWith('now')).length, 2);
    });

    test('unknown duration (stream) falls back to the 4 minute threshold', () {
      tracker.trackChanged('radio', 0);
      expect(tracker.thresholdMs, 240000);
      tracker.durationKnown(100000);
      expect(tracker.thresholdMs, 50000);
    });
  });

  group('SleepTimer', () {
    test('fires after the set minutes and reports remaining time', () {
      fakeAsync((fa) {
        var fired = 0;
        final states = <SleepTimerState>[];
        final t = SleepTimer(onExpire: () => fired++, now: fa.getClock(DateTime(2024)).now);
        t.stream.listen(states.add);
        t.startMinutes(2);
        fa.elapse(const Duration(seconds: 30));
        expect(t.state.mode, SleepMode.minutes);
        expect(t.state.remaining!.inSeconds, inInclusiveRange(89, 91));
        expect(fired, 0);
        fa.elapse(const Duration(seconds: 91));
        expect(fired, 1);
        expect(t.state.active, isFalse);
        fa.elapse(const Duration(minutes: 5));
        expect(fired, 1, reason: 'fires once');
        t.dispose();
      });
    });

    test('cancel stops it', () {
      fakeAsync((fa) {
        var fired = 0;
        final t = SleepTimer(onExpire: () => fired++, now: fa.getClock(DateTime(2024)).now)..startMinutes(1);
        fa.elapse(const Duration(seconds: 20));
        t.cancel();
        fa.elapse(const Duration(minutes: 2));
        expect(fired, 0);
        expect(t.state.mode, SleepMode.off);
        t.dispose();
      });
    });

    test('extend adds time to a running timer', () {
      fakeAsync((fa) {
        var fired = 0;
        final t = SleepTimer(onExpire: () => fired++, now: fa.getClock(DateTime(2024)).now)..startMinutes(1);
        fa.elapse(const Duration(seconds: 50));
        t.extend(const Duration(minutes: 5));
        fa.elapse(const Duration(minutes: 4));
        expect(fired, 0);
        fa.elapse(const Duration(minutes: 2));
        expect(fired, 1);
        t.dispose();
      });
    });

    test('end-of-track mode waits for trackFinished', () {
      fakeAsync((fa) {
        var fired = 0;
        final t = SleepTimer(onExpire: () => fired++, now: fa.getClock(DateTime(2024)).now)..startEndOfTrack();
        fa.elapse(const Duration(hours: 1));
        expect(fired, 0);
        t.trackFinished();
        expect(fired, 1);
        t.trackFinished();
        expect(fired, 1);
        t.dispose();
      });
    });

    test('trackFinished is ignored in minutes mode', () {
      fakeAsync((fa) {
        var fired = 0;
        final t = SleepTimer(onExpire: () => fired++, now: fa.getClock(DateTime(2024)).now)..startMinutes(10);
        t.trackFinished();
        expect(fired, 0);
        t.dispose();
      });
    });
  });

  group('MediaItem mapping', () {
    const track = Track(
      id: 7,
      filePath: '/storage/emulated/0/Music/a.mp3',
      title: 'Song',
      dateAdded: 1,
      artistName: 'Artist',
      albumTitle: 'Album',
      albumId: 3,
      artistId: 2,
      durationMs: 123000,
      replayGainTrack: -5.5,
      source: TrackSource.youtube,
      sourceUrl: 'https://www.youtube.com/watch?v=x',
      lyricsOffsetMs: 250,
    );

    test('carries the fields the handler needs', () {
      final m = trackToMediaItem(track);
      expect(m.id, 'file:///storage/emulated/0/Music/a.mp3');
      expect(m.title, 'Song');
      expect(m.artist, 'Artist');
      expect(m.duration, const Duration(milliseconds: 123000));
      expect(m.trackId, 7);
      expect(m.rgTrack, -5.5);
      expect(m.rgAlbum, isNull);
      expect(m.albumId, 3);
      expect(m.lyricsOffsetMs, 250);
      expect(m.playKey, 'track:7');
      expect(m.isRemote, isFalse);
    });

    test('survives a JSON round trip (queue persistence)', () {
      final m = trackToMediaItem(track, art: Uri.parse('file:///cache/a.jpg'));
      final back = mediaItemFromJson(mediaItemToJson(m));
      expect(back.id, m.id);
      expect(back.artUri.toString(), 'file:///cache/a.jpg');
      expect(back.duration, m.duration);
      expect(back.trackId, 7);
      expect(back.rgTrack, -5.5);
    });

    test('remote items key on their URL', () {
      const m = MediaItem(id: 'https://stream/x', title: 'T', extras: {MediaExtras.remote: true, MediaExtras.resolveUrl: 'https://youtu.be/x'});
      expect(m.isRemote, isTrue);
      expect(m.resolveUrl, 'https://youtu.be/x');
      expect(m.playKey, 'url:https://youtu.be/x');
    });

    test('content URI tracks play through their URI', () {
      const t = Track(id: 1, filePath: 'content://tree/doc', contentUri: 'content://tree/doc', title: 'x', dateAdded: 0);
      expect(trackToMediaItem(t).id, 'content://tree/doc');
    });
  });
}
