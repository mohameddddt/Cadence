import '../../core/net/http_service.dart';

class AcoustIdArtist {
  const AcoustIdArtist({required this.id, required this.name});
  final String id;
  final String name;
}

class AcoustIdReleaseGroup {
  const AcoustIdReleaseGroup({required this.id, required this.title, this.type, this.artists = const []});
  final String id;
  final String title;
  final String? type;
  final List<AcoustIdArtist> artists;
}

class AcoustIdRecording {
  const AcoustIdRecording({
    required this.id,
    this.title,
    this.durationSec,
    this.artists = const [],
    this.releaseGroups = const [],
  });

  final String id; // MusicBrainz recording id
  final String? title;
  final int? durationSec;
  final List<AcoustIdArtist> artists;
  final List<AcoustIdReleaseGroup> releaseGroups;

  String get artistName => artists.map((a) => a.name).join(', ');
}

class AcoustIdResult {
  const AcoustIdResult({required this.acoustId, required this.score, this.recordings = const []});

  final String acoustId;
  final double score; // 0..1
  final List<AcoustIdRecording> recordings;
}

/// AcoustID web service `/v2/lookup` (3 requests/second, application key required).
class AcoustIdClient {
  AcoustIdClient(this.http, {required this.apiKey, this.base = 'https://api.acoustid.org/v2'});

  final HttpService http;
  final String Function() apiKey;
  final String base;

  bool get isConfigured => apiKey().trim().isNotEmpty;

  /// Looks up [fingerprint] (compressed, base64) of a track lasting [durationSeconds].
  /// Results are sorted best score first.
  Future<List<AcoustIdResult>> lookup({required String fingerprint, required int durationSeconds}) async {
    if (!isConfigured) throw StateError('AcoustID application key not set (Settings > Accounts)');
    // POST because 2 minutes of fingerprint make a URL too long for some proxies.
    final j = await http.postForm(
      '$base/lookup',
      fields: {
        'client': apiKey().trim(),
        'duration': '$durationSeconds',
        'fingerprint': fingerprint,
        'meta': 'recordings+releasegroups+compress',
        'format': 'json',
      },
    );
    if (j is! Map || j['status'] != 'ok') {
      var err = 'unexpected response';
      if (j is Map && j['error'] is Map) err = (j['error'] as Map)['message']?.toString() ?? err;
      throw HttpFailure('AcoustID: $err');
    }
    final results = <AcoustIdResult>[];
    for (final r in (j['results'] as List?) ?? const []) {
      final m = (r as Map).cast<String, dynamic>();
      results.add(AcoustIdResult(
        acoustId: m['id'] as String,
        score: (m['score'] as num?)?.toDouble() ?? 0,
        recordings: [
          for (final rec in (m['recordings'] as List?) ?? const [])
            _recording((rec as Map).cast<String, dynamic>()),
        ],
      ));
    }
    results.sort((a, b) => b.score.compareTo(a.score));
    return results;
  }

  AcoustIdRecording _recording(Map<String, dynamic> m) => AcoustIdRecording(
        id: m['id'] as String,
        title: m['title'] as String?,
        durationSec: (m['duration'] as num?)?.toInt(),
        artists: _artists(m['artists']),
        releaseGroups: [
          for (final g in (m['releasegroups'] as List?) ?? const [])
            AcoustIdReleaseGroup(
              id: (g as Map)['id'] as String,
              title: (g['title'] ?? '') as String,
              type: g['type'] as String?,
              artists: _artists(g['artists']),
            ),
        ],
      );

  List<AcoustIdArtist> _artists(Object? raw) => [
        for (final a in (raw as List?) ?? const []) AcoustIdArtist(id: (a as Map)['id'] as String, name: (a['name'] ?? '') as String),
      ];
}
