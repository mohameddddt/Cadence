import '../../core/net/http_service.dart';
import 'musicbrainz_models.dart';

class MbArtist {
  const MbArtist({
    required this.id,
    required this.name,
    this.sortName,
    this.type,
    this.country,
    this.begin,
    this.end,
    this.disambiguation,
    this.genres = const [],
    this.links = const {},
  });

  final String id;
  final String name;
  final String? sortName;
  final String? type;
  final String? country;
  final String? begin;
  final String? end;
  final String? disambiguation;
  final List<String> genres;

  /// Relation type (wikidata, discogs, bandcamp, "official homepage", "social network"...) -> URL.
  final Map<String, List<String>> links;

  String? link(String type) => links[type]?.firstOrNull;

  factory MbArtist.fromJson(Map<String, dynamic> j) {
    final links = <String, List<String>>{};
    for (final r in (j['relations'] as List?) ?? const []) {
      final m = r as Map;
      final url = (m['url'] as Map?)?['resource'] as String?;
      final type = m['type'] as String?;
      if (url != null && type != null) links.putIfAbsent(type, () => []).add(url);
    }
    final life = j['life-span'] as Map?;
    return MbArtist(
      id: j['id'] as String,
      name: j['name'] as String,
      sortName: j['sort-name'] as String?,
      type: j['type'] as String?,
      country: j['country'] as String?,
      begin: life?['begin'] as String?,
      end: life?['end'] as String?,
      disambiguation: (j['disambiguation'] as String?)?.isEmpty == true ? null : j['disambiguation'] as String?,
      genres: [
        for (final g in (j['genres'] as List?) ?? const [])
          if ((g as Map)['name'] != null) g['name'] as String,
      ],
      links: links,
    );
  }
}

class MbReleaseGroup {
  const MbReleaseGroup({
    required this.id,
    required this.title,
    this.primaryType,
    this.secondaryTypes = const [],
    this.firstReleaseDate,
  });

  final String id;
  final String title;
  final String? primaryType;
  final List<String> secondaryTypes;
  final String? firstReleaseDate;

  int? get year => (firstReleaseDate == null || firstReleaseDate!.length < 4) ? null : int.tryParse(firstReleaseDate!.substring(0, 4));

  factory MbReleaseGroup.fromJson(Map<String, dynamic> j) => MbReleaseGroup(
        id: j['id'] as String,
        title: (j['title'] ?? '') as String,
        primaryType: j['primary-type'] as String?,
        secondaryTypes: [for (final t in (j['secondary-types'] as List?) ?? const []) t as String],
        firstReleaseDate: (j['first-release-date'] as String?)?.isEmpty == true ? null : j['first-release-date'] as String?,
      );
}

/// Thin typed wrapper over the MusicBrainz web service (JSON).
///
/// Rate limiting (1 request/second) and the mandatory User-Agent are applied by
/// [HttpService]; responses are cached for a long time because MBIDs are stable.
class MusicBrainzClient {
  MusicBrainzClient(this.http, {this.base = 'https://musicbrainz.org/ws/2'});

  final HttpService http;
  final String base;

  Future<MbRecording?> recording(String mbid) async {
    final j = await http.getJsonOrNull(
      '$base/recording/$mbid',
      query: {'inc': 'artists+releases+release-groups+media+isrcs+genres', 'fmt': 'json'},
      ttl: HttpService.longTtl,
    );
    return j == null ? null : MbRecording.fromJson((j as Map).cast<String, dynamic>());
  }

  /// Lucene phrase search on recording + artist, optionally bounded by duration.
  Future<List<MbRecording>> searchRecordings({
    required String title,
    String? artist,
    String? album,
    int? durationMs,
    int limit = 8,
  }) async {
    final parts = <String>['recording:"${escapePhrase(title)}"'];
    if (artist != null && artist.trim().isNotEmpty) parts.add('artist:"${escapePhrase(artist)}"');
    if (album != null && album.trim().isNotEmpty) parts.add('release:"${escapePhrase(album)}"');
    if (durationMs != null && durationMs > 0) {
      // +/- 10 s window around the file's duration
      parts.add('dur:[${durationMs - 10000} TO ${durationMs + 10000}]');
    }
    final j = await http.getJson(
      '$base/recording',
      query: {'query': parts.join(' AND '), 'fmt': 'json', 'limit': limit},
      ttl: HttpService.mediumTtl,
    );
    return [for (final r in (j['recordings'] as List?) ?? const []) MbRecording.fromJson((r as Map).cast<String, dynamic>())];
  }

  Future<MbReleaseDetail?> release(String mbid) async {
    final j = await http.getJsonOrNull(
      '$base/release/$mbid',
      query: {'inc': 'recordings+artist-credits+labels+release-groups', 'fmt': 'json'},
      ttl: HttpService.longTtl,
    );
    return j == null ? null : MbReleaseDetail.fromJson((j as Map).cast<String, dynamic>());
  }

  Future<List<MbRelease>> searchReleases({required String album, String? artist, int limit = 8}) async {
    final parts = <String>['release:"${escapePhrase(album)}"'];
    if (artist != null && artist.trim().isNotEmpty) parts.add('artist:"${escapePhrase(artist)}"');
    final j = await http.getJson(
      '$base/release',
      query: {'query': parts.join(' AND '), 'fmt': 'json', 'limit': limit},
      ttl: HttpService.mediumTtl,
    );
    return [for (final r in (j['releases'] as List?) ?? const []) MbRelease.fromJson((r as Map).cast<String, dynamic>())];
  }

  Future<MbArtist?> artist(String mbid) async {
    final j = await http.getJsonOrNull(
      '$base/artist/$mbid',
      query: {'inc': 'url-rels+genres', 'fmt': 'json'},
      ttl: HttpService.longTtl,
    );
    return j == null ? null : MbArtist.fromJson((j as Map).cast<String, dynamic>());
  }

  Future<List<MbArtist>> searchArtists(String name, {int limit = 5}) async {
    final j = await http.getJson(
      '$base/artist',
      query: {'query': 'artist:"${escapePhrase(name)}"', 'fmt': 'json', 'limit': limit},
      ttl: HttpService.mediumTtl,
    );
    return [for (final a in (j['artists'] as List?) ?? const []) MbArtist.fromJson((a as Map).cast<String, dynamic>())];
  }

  /// All release groups of an artist (albums/EPs/singles), newest last. Used for
  /// "new release" alerts and "download missing albums".
  Future<List<MbReleaseGroup>> releaseGroups(String artistMbid, {String types = 'album|ep|single', int limit = 100}) async {
    final out = <MbReleaseGroup>[];
    var offset = 0;
    while (true) {
      final j = await http.getJson(
        '$base/release-group',
        query: {'artist': artistMbid, 'type': types, 'fmt': 'json', 'limit': limit, 'offset': offset},
        ttl: HttpService.shortTtl,
      );
      final page = [for (final g in (j['release-groups'] as List?) ?? const []) MbReleaseGroup.fromJson((g as Map).cast<String, dynamic>())];
      out.addAll(page);
      final count = (j['release-group-count'] as int?) ?? out.length;
      offset += limit;
      if (page.isEmpty || offset >= count || offset > 1000) break;
    }
    out.sort((a, b) => (a.firstReleaseDate ?? '').compareTo(b.firstReleaseDate ?? ''));
    return out;
  }

  /// Escapes characters that end a quoted Lucene phrase.
  static String escapePhrase(String s) => s.replaceAll('\\', '\\\\').replaceAll('"', '\\"').trim();
}
