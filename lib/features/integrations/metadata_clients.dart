import '../../core/net/http_service.dart';
import '../../core/util/string_similarity.dart';

/// fanart.tv: artist thumbs, backgrounds and logos by MusicBrainz id (free key).
class FanartClient {
  FanartClient(this.http, {required this.apiKey});

  final HttpService http;
  final String Function() apiKey;

  bool get isConfigured => apiKey().isNotEmpty;

  /// Best-liked artist thumbnail URL, or null.
  Future<String?> artistThumb(String mbid) async => (await _images(mbid, 'artistthumb')).firstOrNull;

  Future<String?> artistBackground(String mbid) async => (await _images(mbid, 'artistbackground')).firstOrNull;

  Future<String?> logo(String mbid) async => (await _images(mbid, 'hdmusiclogo')).firstOrNull;

  Future<List<String>> _images(String mbid, String kind) async {
    if (!isConfigured) return const [];
    final j = await http.getJsonOrNull('https://webservice.fanart.tv/v3/music/$mbid', query: {'api_key': apiKey()}, ttl: HttpService.longTtl);
    if (j is! Map) return const [];
    final list = ((j[kind] as List?) ?? const []).cast<Map>().toList()..sort((a, b) => (int.tryParse('${b['likes']}') ?? 0).compareTo(int.tryParse('${a['likes']}') ?? 0));
    return [for (final i in list) i['url'] as String];
  }
}

class AudioDbArtist {
  const AudioDbArtist({required this.name, this.thumb, this.fanart, this.bio, this.genre, this.country, this.formedYear});
  final String name;
  final String? thumb;
  final String? fanart;
  final String? bio;
  final String? genre;
  final String? country;
  final int? formedYear;
}

/// TheAudioDB: artist photos + bios by MusicBrainz id. The public key "2" works for testing.
class AudioDbClient {
  AudioDbClient(this.http, {required this.apiKey});

  final HttpService http;
  final String Function() apiKey;

  Future<AudioDbArtist?> artistByMbid(String mbid) async {
    final key = apiKey().isEmpty ? '2' : apiKey();
    final j = await http.getJsonOrNull('https://www.theaudiodb.com/api/v1/json/$key/artist-mb.php', query: {'i': mbid}, ttl: HttpService.longTtl);
    final artists = (j as Map?)?['artists'] as List?;
    if (artists == null || artists.isEmpty) return null;
    final a = (artists.first as Map).cast<String, dynamic>();
    String? s(String k) {
      final v = a[k] as String?;
      return v == null || v.trim().isEmpty ? null : v;
    }

    return AudioDbArtist(
      name: s('strArtist') ?? '',
      thumb: s('strArtistThumb'),
      fanart: s('strArtistFanart'),
      bio: s('strBiographyEN'),
      genre: s('strGenre'),
      country: s('strCountry'),
      formedYear: int.tryParse(s('intFormedYear') ?? ''),
    );
  }
}

class WikiSummary {
  const WikiSummary({required this.title, required this.extract, this.thumbnail, this.pageUrl});
  final String title;
  final String extract;
  final String? thumbnail;
  final String? pageUrl;
}

/// Wikidata + Wikipedia + Wikimedia Commons: bio, formation info and a free-licensed image
/// (property P18), reached through the artist's Wikidata link in MusicBrainz.
class WikiClient {
  WikiClient(this.http, {this.language = 'en'});

  final HttpService http;
  final String language;

  static String? wikidataId(String? url) {
    if (url == null) return null;
    final m = RegExp(r'(Q\d+)').firstMatch(url);
    return m?.group(1);
  }

  /// Article title + main image file for a Wikidata entity.
  Future<({String? title, String? imageFile})> entity(String qid) async {
    final j = await http.getJsonOrNull(
      'https://www.wikidata.org/w/api.php',
      query: {'action': 'wbgetentities', 'ids': qid, 'props': 'sitelinks|claims', 'sitefilter': '${language}wiki', 'format': 'json'},
      ttl: HttpService.longTtl,
    );
    final e = ((j as Map?)?['entities'] as Map?)?[qid] as Map?;
    if (e == null) return (title: null, imageFile: null);
    final title = (((e['sitelinks'] as Map?)?['${language}wiki']) as Map?)?['title'] as String?;
    final p18 = ((e['claims'] as Map?)?['P18'] as List?)?.firstOrNull as Map?;
    final file = (((p18?['mainsnak'] as Map?)?['datavalue'] as Map?)?['value']) as String?;
    return (title: title, imageFile: file);
  }

  Future<WikiSummary?> summary(String title) async {
    final j = await http.getJsonOrNull('https://$language.wikipedia.org/api/rest_v1/page/summary/${Uri.encodeComponent(title.replaceAll(' ', '_'))}', ttl: HttpService.longTtl);
    if (j is! Map) return null;
    final extract = (j['extract'] as String?)?.trim();
    if (extract == null || extract.isEmpty) return null;
    return WikiSummary(
      title: (j['title'] ?? title) as String,
      extract: extract,
      thumbnail: ((j['originalimage'] ?? j['thumbnail']) as Map?)?['source'] as String?,
      pageUrl: (((j['content_urls'] as Map?)?['desktop']) as Map?)?['page'] as String?,
    );
  }

  /// Direct URL of a Commons file, scaled to [width] px.
  static String commonsUrl(String fileName, {int width = 800}) =>
      'https://commons.wikimedia.org/wiki/Special:FilePath/${Uri.encodeComponent(fileName.replaceAll(' ', '_'))}?width=$width';
}

class DeezerArtist {
  const DeezerArtist({required this.id, required this.name, this.pictureXl, this.fans});
  final int id;
  final String name;
  final String? pictureXl;
  final int? fans;
}

/// Deezer public API (no key): artist pictures, related artists, playlist import.
class DeezerClient {
  DeezerClient(this.http);

  final HttpService http;
  static const _base = 'https://api.deezer.com';

  Future<DeezerArtist?> findArtist(String name) async {
    final j = await http.getJson('$_base/search/artist', query: {'q': name, 'limit': 5}, ttl: HttpService.mediumTtl);
    DeezerArtist? best;
    var bestScore = 0.0;
    for (final a in (((j as Map)['data'] as List?) ?? const [])) {
      final m = a as Map;
      final score = StringSimilarity.ratio(name, m['name'] as String?) + ((m['nb_fan'] as num?) ?? 0) / 1e9;
      if (score > bestScore) {
        bestScore = score;
        best = DeezerArtist(id: (m['id'] as num).toInt(), name: m['name'] as String, pictureXl: (m['picture_xl'] ?? m['picture_big']) as String?, fans: (m['nb_fan'] as num?)?.toInt());
      }
    }
    return bestScore >= 0.85 ? best : null;
  }

  Future<List<DeezerArtist>> relatedArtists(int artistId) async {
    final j = await http.getJson('$_base/artist/$artistId/related', ttl: HttpService.mediumTtl);
    return [
      for (final a in (((j as Map)['data'] as List?) ?? const []))
        DeezerArtist(id: (a as Map)['id'] as int, name: a['name'] as String, pictureXl: a['picture_xl'] as String?),
    ];
  }

  /// Tracks of a public playlist (import feature).
  Future<({String name, List<WishTrack> tracks})> playlist(String id) async {
    final j = await http.getJson('$_base/playlist/$id', ttl: HttpService.shortTtl);
    final m = j as Map;
    final tracks = <WishTrack>[];
    for (final t in ((m['tracks'] as Map?)?['data'] as List?) ?? const []) {
      final tm = t as Map;
      tracks.add(WishTrack(
        artist: (tm['artist'] as Map?)?['name'] as String? ?? '',
        title: (tm['title'] ?? '') as String,
        album: (tm['album'] as Map?)?['title'] as String?,
        durationMs: ((tm['duration'] as num?)?.toInt() ?? 0) * 1000,
      ));
    }
    return (name: (m['title'] ?? 'Deezer playlist') as String, tracks: tracks);
  }
}

class DiscogsRelease {
  const DiscogsRelease({required this.id, required this.title, this.year, this.genres = const [], this.styles = const [], this.label, this.credits = const {}, this.url});
  final int id;
  final String title;
  final int? year;
  final List<String> genres;
  final List<String> styles;
  final String? label;
  final Map<String, List<String>> credits; // role -> names
  final String? url;
}

/// Discogs: detailed credits, pressings, extra genres/styles (token, 60 requests/min).
class DiscogsClient {
  DiscogsClient(this.http, {required this.token});

  final HttpService http;
  final String Function() token;

  bool get isConfigured => token().isNotEmpty;
  Map<String, String> get _auth => {'Authorization': 'Discogs token=${token()}'};

  Future<int?> findRelease({required String artist, required String album}) async {
    if (!isConfigured) return null;
    final j = await http.getJson('https://api.discogs.com/database/search',
        query: {'type': 'release', 'artist': artist, 'release_title': album, 'per_page': 5}, headers: _auth, ttl: HttpService.mediumTtl);
    final results = ((j as Map)['results'] as List?) ?? const [];
    return results.isEmpty ? null : ((results.first as Map)['id'] as num).toInt();
  }

  Future<DiscogsRelease?> release(int id) async {
    if (!isConfigured) return null;
    final j = await http.getJsonOrNull('https://api.discogs.com/releases/$id', headers: _auth, ttl: HttpService.longTtl);
    if (j is! Map) return null;
    final credits = <String, List<String>>{};
    for (final e in (j['extraartists'] as List?) ?? const []) {
      final m = e as Map;
      credits.putIfAbsent((m['role'] ?? 'Other') as String, () => []).add(m['name'] as String);
    }
    return DiscogsRelease(
      id: (j['id'] as num).toInt(),
      title: (j['title'] ?? '') as String,
      year: (j['year'] as num?)?.toInt(),
      genres: [for (final g in (j['genres'] as List?) ?? const []) g as String],
      styles: [for (final g in (j['styles'] as List?) ?? const []) g as String],
      label: ((j['labels'] as List?)?.firstOrNull as Map?)?['name'] as String?,
      credits: credits,
      url: j['uri'] as String?,
    );
  }
}

/// A song on a playlist from another service that we may want to find and download.
class WishTrack {
  const WishTrack({required this.artist, required this.title, this.album, this.isrc, this.durationMs});
  final String artist;
  final String title;
  final String? album;
  final String? isrc;
  final int? durationMs;
}
