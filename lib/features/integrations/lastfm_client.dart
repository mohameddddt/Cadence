import 'package:crypto/crypto.dart';
import 'dart:convert';

import '../../core/net/http_service.dart';

class LastFmError implements Exception {
  LastFmError(this.code, this.message);

  final int code;
  final String message;

  /// The session key is no longer valid: the user must log in again.
  bool get invalidSession => code == 9;

  /// Temporary service failure or rate limit - retry later.
  bool get retryable => code == 11 || code == 16 || code == 29;

  @override
  String toString() => 'LastFmError($code: $message)';
}

class LastFmSimilarTrack {
  const LastFmSimilarTrack({required this.artist, required this.title, required this.match, this.mbid, this.durationSec});
  final String artist;
  final String title;
  final double match;
  final String? mbid;
  final int? durationSec;
}

class LastFmArtistInfo {
  const LastFmArtistInfo({required this.name, this.bio, this.imageUrl, this.tags = const [], this.url, this.listeners});
  final String name;
  final String? bio;
  final String? imageUrl;
  final List<String> tags;
  final String? url;
  final int? listeners;
}

/// One listen to submit.
class ScrobbleItem {
  const ScrobbleItem({required this.artist, required this.title, required this.timestamp, this.album, this.durationSec, this.mbid});
  final String artist;
  final String title;
  final int timestamp; // unix seconds
  final String? album;
  final int? durationSec;
  final String? mbid;
}

/// Last.fm API 2.0: scrobbling, love, similar tracks/artists, bios.
class LastFmClient {
  LastFmClient(this.http, {required this.apiKey, required this.apiSecret, required this.sessionKey, this.base = 'https://ws.audioscrobbler.com/2.0/'});

  final HttpService http;
  final String Function() apiKey;
  final String Function() apiSecret;
  final String? Function() sessionKey;
  final String base;

  bool get hasKey => apiKey().isNotEmpty;
  bool get canScrobble => hasKey && apiSecret().isNotEmpty && (sessionKey() ?? '').isNotEmpty;

  /// Last.fm signature: md5 of the sorted "name+value" pairs (without `format`) + the secret.
  static String sign(Map<String, String> params, String secret) {
    final keys = params.keys.where((k) => k != 'format' && k != 'callback').toList()..sort();
    final b = StringBuffer();
    for (final k in keys) {
      b
        ..write(k)
        ..write(params[k]);
    }
    b.write(secret);
    return md5.convert(utf8.encode(b.toString())).toString();
  }

  Future<Map<String, dynamic>> _read(String method, Map<String, String> params) async {
    final j = await http.getJson(base, query: {'method': method, 'api_key': apiKey(), 'format': 'json', ...params}, ttl: HttpService.mediumTtl);
    return _check(j);
  }

  Map<String, dynamic> _check(dynamic j) {
    if (j is Map && j['error'] != null) throw LastFmError((j['error'] as num).toInt(), (j['message'] ?? '') as String);
    return (j as Map).cast<String, dynamic>();
  }

  Future<Map<String, dynamic>> _write(String method, Map<String, String> params) async {
    final all = {'method': method, 'api_key': apiKey(), 'sk': sessionKey() ?? '', ...params};
    all['api_sig'] = sign(all, apiSecret());
    all['format'] = 'json';
    final j = await http.postForm(base, fields: all);
    return _check(j);
  }

  /// Log in with username + password (mobile auth). Returns (name, session key).
  Future<({String name, String key})> login(String username, String password) async {
    final params = {'method': 'auth.getMobileSession', 'api_key': apiKey(), 'username': username, 'password': password};
    final signed = {...params, 'api_sig': sign(params, apiSecret()), 'format': 'json'};
    final j = _check(await http.postForm('https://ws.audioscrobbler.com/2.0/', fields: signed));
    final s = j['session'] as Map;
    return (name: s['name'] as String, key: s['key'] as String);
  }

  Future<void> updateNowPlaying({required String artist, required String title, String? album, int? durationSec}) async {
    await _write('track.updateNowPlaying', {
      'artist': artist,
      'track': title,
      if (album != null && album.isNotEmpty) 'album': album,
      if (durationSec != null && durationSec > 0) 'duration': '$durationSec',
    });
  }

  /// Submits up to 50 listens. Returns how many were accepted.
  Future<int> scrobble(List<ScrobbleItem> items) async {
    if (items.isEmpty) return 0;
    final batch = items.take(50).toList();
    final params = <String, String>{};
    for (var i = 0; i < batch.length; i++) {
      final s = batch[i];
      params['artist[$i]'] = s.artist;
      params['track[$i]'] = s.title;
      params['timestamp[$i]'] = '${s.timestamp}';
      if (s.album != null && s.album!.isNotEmpty) params['album[$i]'] = s.album!;
      if (s.durationSec != null && s.durationSec! > 0) params['duration[$i]'] = '${s.durationSec}';
      if (s.mbid != null && s.mbid!.isNotEmpty) params['mbid[$i]'] = s.mbid!;
    }
    final j = await _write('track.scrobble', params);
    final attr = (j['scrobbles'] as Map?)?['@attr'] as Map?;
    return (attr?['accepted'] as num?)?.toInt() ?? batch.length;
  }

  Future<void> love(String artist, String title, {bool love = true}) async {
    await _write(love ? 'track.love' : 'track.unlove', {'artist': artist, 'track': title});
  }

  Future<List<LastFmSimilarTrack>> similarTracks(String artist, String title, {int limit = 30}) async {
    final j = await _read('track.getsimilar', {'artist': artist, 'track': title, 'limit': '$limit', 'autocorrect': '1'});
    final list = ((j['similartracks'] as Map?)?['track'] as List?) ?? const [];
    return [
      for (final t in list)
        LastFmSimilarTrack(
          artist: ((t as Map)['artist'] as Map)['name'] as String,
          title: t['name'] as String,
          match: double.tryParse('${t['match']}') ?? 0,
          mbid: (t['mbid'] as String?)?.isEmpty == true ? null : t['mbid'] as String?,
          durationSec: int.tryParse('${t['duration']}'),
        ),
    ];
  }

  Future<List<({String name, String? mbid, double match})>> similarArtists(String artist, {int limit = 20}) async {
    final j = await _read('artist.getsimilar', {'artist': artist, 'limit': '$limit', 'autocorrect': '1'});
    final list = ((j['similarartists'] as Map?)?['artist'] as List?) ?? const [];
    return [
      for (final a in list)
        (name: (a as Map)['name'] as String, mbid: (a['mbid'] as String?)?.isEmpty == true ? null : a['mbid'] as String?, match: double.tryParse('${a['match']}') ?? 0),
    ];
  }

  Future<LastFmArtistInfo?> artistInfo(String artist, {String? mbid}) async {
    try {
      final j = await _read('artist.getinfo', {if (mbid != null) 'mbid': mbid else 'artist': artist, 'autocorrect': '1'});
      final a = j['artist'];
      if (a is! Map) return null;
      final bio = (a['bio'] as Map?)?['summary'] as String?;
      String? image;
      for (final size in const ['mega', 'extralarge', 'large']) {
        for (final i in (a['image'] as List?) ?? const []) {
          if ((i as Map)['size'] == size && (i['#text'] as String?)?.isNotEmpty == true) {
            image = i['#text'] as String;
            break;
          }
        }
        if (image != null) break;
      }
      return LastFmArtistInfo(
        name: a['name'] as String,
        bio: bio == null ? null : stripHtml(bio),
        imageUrl: image,
        tags: [for (final t in ((a['tags'] as Map?)?['tag'] as List?) ?? const []) (t as Map)['name'] as String],
        url: a['url'] as String?,
        listeners: int.tryParse('${(a['stats'] as Map?)?['listeners']}'),
      );
    } on LastFmError catch (e) {
      if (e.code == 6) return null; // artist not found
      rethrow;
    }
  }

  /// Bios contain a trailing "<a href>Read more on Last.fm</a>" link.
  static String stripHtml(String s) => s.replaceAll(RegExp(r'<a [^>]*>.*?</a>', dotAll: true), '').replaceAll(RegExp(r'<[^>]+>'), '').trim();
}
