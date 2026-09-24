import 'dart:async';

enum SleepMode { off, minutes, endOfTrack }

class SleepTimerState {
  const SleepTimerState(this.mode, {this.remaining});

  static const SleepTimerState off = SleepTimerState(SleepMode.off);

  final SleepMode mode;

  /// Time left for [SleepMode.minutes].
  final Duration? remaining;

  bool get active => mode != SleepMode.off;
}

/// Stops playback after N minutes or at the end of the current track.
///
/// The "end of track" case is completed by the caller via [trackFinished].
class SleepTimer {
  SleepTimer({
    required this.onExpire,
    DateTime Function()? now,
    Duration tick = const Duration(seconds: 1),
  })  : _now = now ?? DateTime.now,
        _tickEvery = tick;

  /// Called once when the timer fires.
  final void Function() onExpire;
  final DateTime Function() _now;
  final Duration _tickEvery;

  final StreamController<SleepTimerState> _state = StreamController<SleepTimerState>.broadcast();
  SleepTimerState _current = SleepTimerState.off;
  Timer? _timer;
  DateTime? _deadline;

  SleepTimerState get state => _current;
  Stream<SleepTimerState> get stream => _state.stream;

  void startMinutes(int minutes) {
    cancel();
    _deadline = _now().add(Duration(minutes: minutes));
    _timer = Timer.periodic(_tickEvery, (_) => _tick());
    _emit(SleepTimerState(SleepMode.minutes, remaining: Duration(minutes: minutes)));
  }

  void startEndOfTrack() {
    cancel();
    _emit(const SleepTimerState(SleepMode.endOfTrack));
  }

  /// Adds time to a running minutes timer (the "+5 min" button).
  void extend(Duration by) {
    if (_current.mode != SleepMode.minutes || _deadline == null) return;
    _deadline = _deadline!.add(by);
    _tick(silentExpiry: true);
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    _deadline = null;
    if (_current.active) _emit(SleepTimerState.off);
  }

  /// The player reports that the current track ended.
  void trackFinished() {
    if (_current.mode == SleepMode.endOfTrack) {
      _emit(SleepTimerState.off);
      onExpire();
    }
  }

  void _tick({bool silentExpiry = false}) {
    final d = _deadline;
    if (d == null) return;
    final left = d.difference(_now());
    if (left <= Duration.zero) {
      _timer?.cancel();
      _timer = null;
      _deadline = null;
      _emit(SleepTimerState.off);
      if (!silentExpiry) onExpire();
      return;
    }
    _emit(SleepTimerState(SleepMode.minutes, remaining: left));
  }

  void _emit(SleepTimerState s) {
    _current = s;
    if (!_state.isClosed) _state.add(s);
  }

  void dispose() {
    _timer?.cancel();
    _state.close();
  }
}
