/// Decides when a listen "counts" (play statistics + scrobbling).
///
/// Last.fm rule: the track must be longer than 30 s and be played for at least half of its
/// length or 4 minutes, whichever comes first. Seeking does not add listening time.
class PlayTracker {
  PlayTracker({
    this.onNowPlaying,
    this.onCounted,
    this.minScrobbleLengthMs = 30000,
    this.maxThresholdMs = 240000,
  });

  /// Called when a new track starts.
  final void Function(String key)? onNowPlaying;

  /// Called once per listen. [scrobbleEligible] is false for tracks under 30 s.
  final void Function(String key, {required bool scrobbleEligible})? onCounted;

  final int minScrobbleLengthMs;
  final int maxThresholdMs;

  String? _key;
  int _durationMs = 0;
  int _listenedMs = 0;
  int _lastPositionMs = 0;
  bool _counted = false;

  String? get currentKey => _key;
  int get listenedMs => _listenedMs;
  bool get counted => _counted;

  /// A new track became current.
  void trackChanged(String? key, int durationMs) {
    _key = key;
    _durationMs = durationMs;
    _listenedMs = 0;
    _lastPositionMs = 0;
    _counted = false;
    if (key != null) onNowPlaying?.call(key);
  }

  /// Duration often arrives after the track change (streams, first load).
  void durationKnown(int durationMs) {
    if (durationMs > 0) _durationMs = durationMs;
  }

  int get thresholdMs {
    if (_durationMs <= 0) return maxThresholdMs;
    final half = _durationMs ~/ 2;
    return half < maxThresholdMs ? half : maxThresholdMs;
  }

  /// Feed the player position regularly (every ~0.5-1 s).
  void tick(int positionMs, {required bool playing}) {
    final key = _key;
    if (key == null) return;
    final delta = positionMs - _lastPositionMs;
    if (_counted && positionMs + 5000 < _lastPositionMs) {
      // Repeat-one (or a manual restart) after the listen was counted: a new listen starts.
      _listenedMs = 0;
      _counted = false;
      onNowPlaying?.call(key);
    } else if (playing && delta > 0 && delta <= 2000) {
      // Only continuous progress counts; a seek is a jump.
      _listenedMs += delta;
    }
    _lastPositionMs = positionMs;

    if (!_counted && _listenedMs >= thresholdMs && _listenedMs > 0) {
      _counted = true;
      onCounted?.call(key, scrobbleEligible: _durationMs == 0 || _durationMs >= minScrobbleLengthMs);
    }
  }
}
