import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;

import '../db/app_database.dart';

/// Response cache backed by the api_cache table (offline-first rule #2).
abstract class ApiCache {
  Future<String?> get(String key);
  Future<void> put(String key, String response, Duration ttl);
  Future<int> purgeExpired();

  /// Stable key for a request: method + url + sorted query + selected headers.
  static String keyFor(String method, Uri uri, {Map<String, String>? vary}) {
    final params = uri.queryParametersAll.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    final canonical = StringBuffer('$method ${uri.scheme}://${uri.host}${uri.path}?');
    for (final e in params) {
      for (final v in (e.value.toList()..sort())) {
        canonical.write('${e.key}=$v&');
      }
    }
    if (vary != null) {
      final keys = vary.keys.toList()..sort();
      for (final k in keys) {
        canonical.write('|$k:${vary[k]}');
      }
    }
    return sha1.convert(utf8.encode(canonical.toString())).toString();
  }
}

class DbApiCache implements ApiCache {
  DbApiCache(this.appDb);
  final AppDatabase appDb;

  int get _now => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  @override
  Future<String?> get(String key) async {
    final rows = await appDb.db.query('api_cache', where: 'key = ? AND expires_at > ?', whereArgs: [key, _now], limit: 1);
    return rows.isEmpty ? null : rows.first['response'] as String;
  }

  @override
  Future<void> put(String key, String response, Duration ttl) async {
    await appDb.db.insert(
      'api_cache',
      {'key': key, 'response': response, 'expires_at': _now + ttl.inSeconds},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<int> purgeExpired() => appDb.db.delete('api_cache', where: 'expires_at <= ?', whereArgs: [_now]);
}

class MemoryApiCache implements ApiCache {
  final Map<String, ({String value, DateTime expires})> _m = {};

  @override
  Future<String?> get(String key) async {
    final e = _m[key];
    if (e == null || e.expires.isBefore(DateTime.now())) return null;
    return e.value;
  }

  @override
  Future<void> put(String key, String response, Duration ttl) async {
    _m[key] = (value: response, expires: DateTime.now().add(ttl));
  }

  @override
  Future<int> purgeExpired() async {
    final now = DateTime.now();
    final before = _m.length;
    _m.removeWhere((_, v) => v.expires.isBefore(now));
    return before - _m.length;
  }
}
