import 'dart:async';

import '../../core/db/app_database.dart';
import '../../core/settings/settings_store.dart';
import 'lastfm_client.dart';
import 'listenbrainz_client.dart';

class FlushResult {
  const FlushResult({this.lastFm = 0, this.listenBrainz = 0, this.pending = 0, this.errors = const []});
  final int lastFm;
  final int listenBrainz;
  final int pending;
  final List<String> errors;
}

/// Offline-capable scrobbling: listens are stored first, then sent to Last.fm and/or
/// ListenBrainz when the network works. Nothing is ever lost because a request failed.
class ScrobbleService {
  ScrobbleService({required this.appDb, required this.settings, required this.lastFm, required this.listenBrainz, DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final AppDatabase appDb;
  final SettingsStore settings;
  final LastFmClient lastFm;
  final ListenBrainzClient listenBrainz;
  final DateTime Function() _now;

  Timer? _debounce;
  bool _flushing = false;

  /// Last.fm rejects listens older than 14 days; keep them for ListenBrainz only.
  static const Duration lastFmMaxAge = Duration(days: 14);

  bool get lastFmEnabled => settings.scrobbleLastFm && lastFm.canScrobble;
  bool get listenBrainzEnabled => settings.scrobbleListenBrainz && listenBrainz.isConfigured;

  Future<int> pendingCount() async {
    final rows = await appDb.db.rawQuery('SELECT COUNT(*) AS n FROM scrobble_queue WHERE lastfm_done = 0 OR lb_done = 0');
    return (rows.first['n'] as int?) ?? 0;
  }

  /// A track started playing ("now playing" is best-effort and never queued).
  Future<void> nowPlaying(ScrobbleItem item) async {
    if (lastFmEnabled) {
      try {
        await lastFm.updateNowPlaying(artist: item.artist, title: item.title, album: item.album, durationSec: item.durationSec);
      } on Exception {
        // not critical
      }
    }
    if (listenBrainzEnabled) {
      try {
        await listenBrainz.nowPlaying(item);
      } on Exception {
        // not critical
      }
    }
  }

  /// A listen counted (>= 50 % / 4 min): store it, then try to send soon.
  Future<void> record(ScrobbleItem item, {int? trackId}) async {
    if (!lastFmEnabled && !listenBrainzEnabled) return;
    await appDb.db.insert('scrobble_queue', {
      'track_id': trackId,
      'artist': item.artist,
      'title': item.title,
      'album': item.album,
      'duration_ms': item.durationSec == null ? null : item.durationSec! * 1000,
      'mb_recording_id': item.mbid,
      'timestamp': item.timestamp,
      // A service that is off does not hold the row back.
      'lastfm_done': lastFmEnabled ? 0 : 1,
      'lb_done': listenBrainzEnabled ? 0 : 1,
    });
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 3), () => flush());
  }

  /// Sends everything pending. Returns counts; errors are reported, not thrown.
  Future<FlushResult> flush() async {
    if (_flushing) return FlushResult(pending: await pendingCount());
    _flushing = true;
    var sentLf = 0, sentLb = 0;
    final errors = <String>[];
    try {
      if (lastFmEnabled) {
        sentLf = await _flushLastFm(errors);
      } else {
        await appDb.db.update('scrobble_queue', {'lastfm_done': 1}, where: 'lastfm_done = 0');
      }
      if (listenBrainzEnabled) {
        sentLb = await _flushListenBrainz(errors);
      } else {
        await appDb.db.update('scrobble_queue', {'lb_done': 1}, where: 'lb_done = 0');
      }
      await appDb.db.delete('scrobble_queue', where: 'lastfm_done = 1 AND lb_done = 1');
    } finally {
      _flushing = false;
    }
    return FlushResult(lastFm: sentLf, listenBrainz: sentLb, pending: await pendingCount(), errors: errors);
  }

  Future<int> _flushLastFm(List<String> errors) async {
    var sent = 0;
    final cutoff = _now().subtract(lastFmMaxAge).millisecondsSinceEpoch ~/ 1000;
    // too old for Last.fm: drop that service's flag
    await appDb.db.update('scrobble_queue', {'lastfm_done': 1}, where: 'lastfm_done = 0 AND timestamp < ?', whereArgs: [cutoff]);
    while (true) {
      final rows = await appDb.db.query('scrobble_queue', where: 'lastfm_done = 0', orderBy: 'timestamp', limit: 50);
      if (rows.isEmpty) break;
      try {
        await lastFm.scrobble([for (final r in rows) _item(r)]);
        await _mark(rows, 'lastfm_done');
        sent += rows.length;
      } on LastFmError catch (e) {
        if (e.invalidSession) {
          errors.add('Last.fm login expired - sign in again in Settings.');
          await settings.setLastFmSession(null);
          break;
        }
        if (e.retryable) {
          errors.add('Last.fm is busy, will retry (${e.message}).');
          break;
        }
        // A permanent rejection (blocked artist, bad data): do not retry forever.
        errors.add('Last.fm rejected a batch: ${e.message}');
        await _mark(rows, 'lastfm_done');
      } on Exception catch (e) {
        errors.add('Last.fm unreachable: $e');
        break;
      }
    }
    return sent;
  }

  Future<int> _flushListenBrainz(List<String> errors) async {
    var sent = 0;
    while (true) {
      final rows = await appDb.db.query('scrobble_queue', where: 'lb_done = 0', orderBy: 'timestamp', limit: 100);
      if (rows.isEmpty) break;
      try {
        await listenBrainz.submit([for (final r in rows) _item(r)]);
        await _mark(rows, 'lb_done');
        sent += rows.length;
      } on ListenBrainzError catch (e) {
        if (e.invalidToken) {
          errors.add('ListenBrainz token rejected.');
          break;
        }
        if ((e.statusCode >= 400 && e.statusCode < 500) && e.statusCode != 429) {
          errors.add('ListenBrainz rejected a batch: ${e.message}');
          await _mark(rows, 'lb_done');
          continue;
        }
        errors.add('ListenBrainz busy, will retry.');
        break;
      } on Exception catch (e) {
        errors.add('ListenBrainz unreachable: $e');
        break;
      }
    }
    return sent;
  }

  ScrobbleItem _item(Map<String, Object?> r) => ScrobbleItem(
        artist: r['artist'] as String,
        title: r['title'] as String,
        album: r['album'] as String?,
        durationSec: r['duration_ms'] == null ? null : (r['duration_ms'] as int) ~/ 1000,
        mbid: r['mb_recording_id'] as String?,
        timestamp: r['timestamp'] as int,
      );

  Future<void> _mark(List<Map<String, Object?>> rows, String column) async {
    final ids = rows.map((r) => r['id'] as int).toList();
    await appDb.db.update('scrobble_queue', {column: 1}, where: 'id IN (${List.filled(ids.length, '?').join(',')})', whereArgs: ids);
  }

  void dispose() => _debounce?.cancel();
}
