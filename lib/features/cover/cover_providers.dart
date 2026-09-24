import '../../core/net/http_service.dart';
import '../../core/util/string_similarity.dart';

class CoverQuery {
  const CoverQuery({this.artist, this.album, this.mbReleaseId, this.mbReleaseGroupId});

  final String? artist;
  final String? album;
  final String? mbReleaseId;
  final String? mbReleaseGroupId;

  bool get hasText => (album ?? '').trim().isNotEmpty;
}

class CoverCandidate {
  const CoverCandidate({required this.url, required this.source, this.title, this.width});

  final String url;

  /// Provider id: caa, caa-group, itunes, deezer, lastfm...
  final String source;
  final String? title;
  final int? width;
}

abstract class CoverProvider {
  String get id;
  String get label;

  /// Best match for [q], or null. Implementations must not throw for "not found".
  Future<CoverCandidate?> find(CoverQuery q);

  /// Several options for the manual picker (defaults to the single best match).
  Future<List<CoverCandidate>> candidates(CoverQuery q) async {
    final c = await find(q);
    return c == null ? const [] : [c];
  }
}

String _https(String url) => url.startsWith('http://') ? 'https://${url.substring(7)}' : url;

/// Cover Art Archive by release MBID.
class CoverArtArchiveProvider extends CoverProvider {
  CoverArtArchiveProvider(this.http, {this.byReleaseGroup = false});

  final HttpService http;
  final bool byReleaseGroup;

  @override
  String get id => byReleaseGroup ? 'caa-group' : 'caa';

  @override
  String get label => byReleaseGroup ? 'Cover Art Archive (release group)' : 'Cover Art Archive';

  @override
  Future<CoverCandidate?> find(CoverQuery q) async {
    final mbid = byReleaseGroup ? q.mbReleaseGroupId : q.mbReleaseId;
    if (mbid == null || mbid.isEmpty) return null;
    try {
      final kind = byReleaseGroup ? 'release-group' : 'release';
      final j = await http.getJsonOrNull('https://coverartarchive.org/$kind/$mbid', ttl: HttpService.longTtl);
      if (j is! Map) return null;
      final images = (j['images'] as List?) ?? const [];
      Map? front;
      for (final i in images) {
        if ((i as Map)['front'] == true) {
          front = i;
          break;
        }
      }
      front ??= images.isEmpty ? null : images.first as Map;
      if (front == null) return null;
      final thumbs = (front['thumbnails'] as Map?) ?? const {};
      final url = (thumbs['1200'] ?? thumbs['large'] ?? thumbs['500'] ?? front['image']) as String?;
      if (url == null) return null;
      return CoverCandidate(url: _https(url), source: id, width: thumbs['1200'] != null ? 1200 : null);
    } on HttpFailure {
      return null;
    }
  }
}

/// iTunes Search API (no key). Artwork URLs are resized by editing the size token.
class ITunesCoverProvider extends CoverProvider {
  ITunesCoverProvider(this.http);

  final HttpService http;

  @override
  String get id => 'itunes';

  @override
  String get label => 'iTunes';

  @override
  Future<List<CoverCandidate>> candidates(CoverQuery q) async {
    if (!q.hasText) return const [];
    try {
      final j = await http.getJson(
        'https://itunes.apple.com/search',
        query: {'term': '${q.artist ?? ''} ${q.album}'.trim(), 'entity': 'album', 'limit': 6},
        ttl: HttpService.mediumTtl,
      );
      final out = <(double, CoverCandidate)>[];
      for (final r in (j['results'] as List?) ?? const []) {
        final m = r as Map;
        final art = m['artworkUrl100'] as String?;
        if (art == null) continue;
        final albumSim = StringSimilarity.ratio(q.album, m['collectionName'] as String?);
        final artistSim = q.artist == null ? 0.7 : StringSimilarity.ratio(q.artist, m['artistName'] as String?);
        if (albumSim < 0.6 || artistSim < 0.5) continue;
        out.add((
          albumSim * 0.7 + artistSim * 0.3,
          CoverCandidate(
            url: art.replaceAll(RegExp(r'\d+x\d+bb'), '1200x1200bb'),
            source: id,
            title: '${m['artistName']} - ${m['collectionName']}',
            width: 1200,
          ),
        ));
      }
      out.sort((a, b) => b.$1.compareTo(a.$1));
      return [for (final e in out) e.$2];
    } on HttpFailure {
      return const [];
    }
  }

  @override
  Future<CoverCandidate?> find(CoverQuery q) async => (await candidates(q)).firstOrNull;
}

/// Deezer public API: `cover_xl` is 1000x1000.
class DeezerCoverProvider extends CoverProvider {
  DeezerCoverProvider(this.http);

  final HttpService http;

  @override
  String get id => 'deezer';

  @override
  String get label => 'Deezer';

  @override
  Future<List<CoverCandidate>> candidates(CoverQuery q) async {
    if (!q.hasText) return const [];
    try {
      final query = q.artist == null ? 'album:"${q.album}"' : 'artist:"${q.artist}" album:"${q.album}"';
      final j = await http.getJson('https://api.deezer.com/search/album', query: {'q': query, 'limit': 6}, ttl: HttpService.mediumTtl);
      final out = <(double, CoverCandidate)>[];
      for (final r in (j['data'] as List?) ?? const []) {
        final m = r as Map;
        final cover = (m['cover_xl'] ?? m['cover_big']) as String?;
        if (cover == null || cover.isEmpty) continue;
        final artist = (m['artist'] as Map?)?['name'] as String?;
        final albumSim = StringSimilarity.ratio(q.album, m['title'] as String?);
        final artistSim = q.artist == null ? 0.7 : StringSimilarity.ratio(q.artist, artist);
        if (albumSim < 0.6 || artistSim < 0.5) continue;
        out.add((albumSim * 0.7 + artistSim * 0.3, CoverCandidate(url: cover, source: id, title: '$artist - ${m['title']}', width: 1000)));
      }
      out.sort((a, b) => b.$1.compareTo(a.$1));
      return [for (final e in out) e.$2];
    } on HttpFailure {
      return const [];
    }
  }

  @override
  Future<CoverCandidate?> find(CoverQuery q) async => (await candidates(q)).firstOrNull;
}

/// Last.fm `album.getInfo` (needs an API key).
class LastFmCoverProvider extends CoverProvider {
  LastFmCoverProvider(this.http, {required this.apiKey});

  final HttpService http;
  final String Function() apiKey;

  @override
  String get id => 'lastfm';

  @override
  String get label => 'Last.fm';

  @override
  Future<CoverCandidate?> find(CoverQuery q) async {
    if (apiKey().isEmpty || !q.hasText || (q.artist ?? '').isEmpty) return null;
    try {
      final j = await http.getJson(
        'https://ws.audioscrobbler.com/2.0/',
        query: {'method': 'album.getinfo', 'api_key': apiKey(), 'artist': q.artist, 'album': q.album, 'format': 'json', 'autocorrect': 1},
        ttl: HttpService.mediumTtl,
      );
      final images = ((j['album'] as Map?)?['image'] as List?) ?? const [];
      String? best;
      for (final size in const ['mega', 'extralarge', 'large']) {
        for (final i in images) {
          final m = i as Map;
          if (m['size'] == size && (m['#text'] as String?)?.isNotEmpty == true) {
            best = m['#text'] as String;
            break;
          }
        }
        if (best != null) break;
      }
      if (best == null || best.contains('2a96cbd8b46e442fc41c2b86b821562f')) return null; // Last.fm's grey placeholder
      return CoverCandidate(url: best, source: id);
    } on HttpFailure {
      return null;
    }
  }
}
