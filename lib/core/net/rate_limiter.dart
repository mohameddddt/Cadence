import 'dart:async';

/// Per-host request pacing shared by every API client (design rule #4).
///
/// Each host has a minimum interval between request *starts*. Requests are served
/// in the order [acquire] was called, so a burst of callers turns into an orderly
/// queue instead of a blocked IP (MusicBrainz allows 1 request/second).
class HostRateLimiter {
  HostRateLimiter({
    Map<String, Duration>? intervals,
    DateTime Function()? now,
    Future<void> Function(Duration)? delay,
  })  : _intervals = {...defaultIntervals, ...?intervals},
        _now = now ?? DateTime.now,
        _delay = delay ?? Future<void>.delayed;

  /// Conservative defaults taken from each service's published limits.
  static const Map<String, Duration> defaultIntervals = {
    'musicbrainz.org': Duration(milliseconds: 1100),
    'api.acoustid.org': Duration(milliseconds: 350),
    'lrclib.net': Duration(milliseconds: 250),
    'ws.audioscrobbler.com': Duration(milliseconds: 250),
    'api.listenbrainz.org': Duration(milliseconds: 250),
    'api.deezer.com': Duration(milliseconds: 120),
    'itunes.apple.com': Duration(milliseconds: 3100),
    'api.discogs.com': Duration(milliseconds: 1050),
    'coverartarchive.org': Duration(milliseconds: 200),
    'archive.org': Duration(milliseconds: 250),
    'api.genius.com': Duration(milliseconds: 250),
    'webservice.fanart.tv': Duration(milliseconds: 250),
    'www.theaudiodb.com': Duration(milliseconds: 500),
    'en.wikipedia.org': Duration(milliseconds: 200),
    'www.wikidata.org': Duration(milliseconds: 200),
  };

  final Map<String, Duration> _intervals;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _delay;
  final Map<String, DateTime> _nextSlot = {};

  Duration intervalFor(String host) => _intervals[host] ?? Duration.zero;

  void setInterval(String host, Duration interval) => _intervals[host] = interval;

  /// Completes when the caller may start a request to [host].
  ///
  /// The slot is reserved synchronously so ordering is preserved even when many
  /// callers arrive in the same event-loop turn.
  Future<void> acquire(String host) {
    final interval = intervalFor(host);
    if (interval == Duration.zero) return Future<void>.value();
    final now = _now();
    final next = _nextSlot[host];
    final start = (next != null && next.isAfter(now)) ? next : now;
    _nextSlot[host] = start.add(interval);
    final wait = start.difference(now);
    if (wait <= Duration.zero) return Future<void>.value();
    return _delay(wait);
  }
}
