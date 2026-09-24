import '../../core/net/http_service.dart';
import 'lastfm_client.dart' show ScrobbleItem;

class ListenBrainzError implements Exception {
  ListenBrainzError(this.statusCode, this.message);
  final int statusCode;
  final String message;

  bool get invalidToken => statusCode == 401;

  @override
  String toString() => 'ListenBrainzError($statusCode: $message)';
}

/// ListenBrainz: open scrobbling + similarity data keyed by MusicBrainz ids.
class ListenBrainzClient {
  ListenBrainzClient(this.http, {required this.token, this.base = 'https://api.listenbrainz.org/1', this.labsBase = 'https://labs.api.listenbrainz.org'});

  final HttpService http;
  final String Function() token;
  final String base;
  final String labsBase;

  bool get isConfigured => token().trim().isNotEmpty;

  Map<String, String> get _auth => {'Authorization': 'Token ${token().trim()}'};

  /// Returns the user name for a valid token, null otherwise.
  Future<String?> validate() async {
    if (!isConfigured) return null;
    try {
      final j = await http.getJson('$base/validate-token', headers: _auth);
      return (j as Map)['valid'] == true ? (j['user_name'] as String?) : null;
    } on HttpFailure catch (e) {
      if (e.statusCode == 401) return null;
      rethrow;
    }
  }

  Map<String, dynamic> _listen(ScrobbleItem s, {bool includeTime = true}) => {
        if (includeTime) 'listened_at': s.timestamp,
        'track_metadata': {
          'artist_name': s.artist,
          'track_name': s.title,
          if (s.album != null && s.album!.isNotEmpty) 'release_name': s.album,
          'additional_info': {
            'media_player': 'Cadence',
            'submission_client': 'Cadence',
            if (s.durationSec != null && s.durationSec! > 0) 'duration_ms': s.durationSec! * 1000,
            if (s.mbid != null && s.mbid!.isNotEmpty) 'recording_mbid': s.mbid,
          },
        },
      };

  Future<void> nowPlaying(ScrobbleItem s) async {
    await _submit('playing_now', [_listen(s, includeTime: false)]);
  }

  /// Submits finished listens (one "single" or a batch "import").
  Future<void> submit(List<ScrobbleItem> items) async {
    if (items.isEmpty) return;
    await _submit(items.length == 1 ? 'single' : 'import', [for (final i in items) _listen(i)]);
  }

  Future<void> _submit(String type, List<Map<String, dynamic>> payload) async {
    try {
      await http.postJson('$base/submit-listens', body: {'listen_type': type, 'payload': payload}, headers: _auth);
    } on HttpFailure catch (e) {
      throw ListenBrainzError(e.statusCode ?? 0, e.message);
    }
  }

  /// Similar artists (MusicBrainz ids), best first. Public data set; no token needed.
  Future<List<({String mbid, String name, int score})>> similarArtists(String artistMbid) async {
    final j = await http.getJson(
      '$labsBase/similar-artists/json',
      query: {
        'artist_mbids': artistMbid,
        'algorithm': 'session_based_days_9000_session_300_contribution_5_threshold_15_limit_50_skip_30',
      },
      ttl: HttpService.mediumTtl,
    );
    return [
      for (final a in (j as List? ?? const []))
        (mbid: (a as Map)['artist_mbid'] as String, name: (a['name'] ?? '') as String, score: (a['score'] as num?)?.toInt() ?? 0),
    ];
  }
}
