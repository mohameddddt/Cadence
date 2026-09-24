import '../../core/net/http_service.dart';
import '../../core/util/string_similarity.dart';

class LrclibResult {
  const LrclibResult({
    required this.id,
    required this.trackName,
    required this.artistName,
    this.albumName,
    this.durationSec,
    this.instrumental = false,
    this.plain,
    this.synced,
  });

  final int id;
  final String trackName;
  final String artistName;
  final String? albumName;
  final double? durationSec;
  final bool instrumental;
  final String? plain;
  final String? synced;

  bool get hasSynced => synced != null && synced!.trim().isNotEmpty;
  bool get hasAny => hasSynced || (plain != null && plain!.trim().isNotEmpty);

  factory LrclibResult.fromJson(Map<String, dynamic> j) => LrclibResult(
        id: (j['id'] as num).toInt(),
        trackName: (j['trackName'] ?? j['name'] ?? '') as String,
        artistName: (j['artistName'] ?? '') as String,
        albumName: j['albumName'] as String?,
        durationSec: (j['duration'] as num?)?.toDouble(),
        instrumental: (j['instrumental'] as bool?) ?? false,
        plain: j['plainLyrics'] as String?,
        synced: j['syncedLyrics'] as String?,
      );
}

/// LRCLIB (lrclib.net): open lyrics database, no API key, time-synced (LRC) and plain text.
class LrclibClient {
  LrclibClient(this.http, {this.base = 'https://lrclib.net/api'});

  final HttpService http;
  final String base;

  /// Exact match on title + artist (+ album + duration when known). Null when unknown.
  Future<LrclibResult?> get({required String title, required String artist, String? album, int? durationSec}) async {
    final j = await http.getJsonOrNull(
      '$base/get',
      query: {
        'track_name': title,
        'artist_name': artist,
        if (album != null && album.isNotEmpty) 'album_name': album,
        if (durationSec != null && durationSec > 0) 'duration': durationSec,
      },
      ttl: HttpService.mediumTtl,
    );
    return j is Map ? LrclibResult.fromJson(j.cast<String, dynamic>()) : null;
  }

  /// Fuzzy search; free text or title/artist.
  Future<List<LrclibResult>> search({String? query, String? title, String? artist}) async {
    final j = await http.getJson(
      '$base/search',
      query: {
        if (query != null && query.isNotEmpty) 'q': query,
        if (title != null && title.isNotEmpty) 'track_name': title,
        if (artist != null && artist.isNotEmpty) 'artist_name': artist,
      },
      ttl: HttpService.mediumTtl,
    );
    return [for (final r in (j as List?) ?? const []) LrclibResult.fromJson((r as Map).cast<String, dynamic>())];
  }

  /// Best fuzzy candidate for a track: close duration, similar names, synced preferred.
  static LrclibResult? bestMatch(List<LrclibResult> results, {required String title, String? artist, int? durationSec}) {
    LrclibResult? best;
    var bestScore = 0.0;
    for (final r in results) {
      if (!r.hasAny && !r.instrumental) continue;
      var score = StringSimilarity.ratio(title, r.trackName) * 0.6;
      score += artist == null ? 0.2 : StringSimilarity.ratio(artist, r.artistName) * 0.4;
      if (durationSec != null && durationSec > 0 && r.durationSec != null) {
        final diff = (durationSec - r.durationSec!).abs();
        if (diff > 6) continue; // a different edit/recording: wrong timing
        score += diff <= 2 ? 0.15 : 0.05;
      }
      if (r.hasSynced) score += 0.1;
      if (score > bestScore) {
        bestScore = score;
        best = r;
      }
    }
    return bestScore >= 0.7 ? best : null;
  }
}

class GeniusSong {
  const GeniusSong({
    required this.id,
    required this.title,
    required this.artist,
    required this.url,
    this.thumbnail,
    this.headerImage,
    this.description,
    this.annotationCount,
  });

  final int id;
  final String title;
  final String artist;

  /// The song page. Lyrics text is *not* available through the API; this link is opened
  /// in a browser tab instead.
  final String url;
  final String? thumbnail;
  final String? headerImage;
  final String? description;
  final int? annotationCount;

  factory GeniusSong.fromJson(Map<String, dynamic> j, {String? description}) => GeniusSong(
        id: (j['id'] as num).toInt(),
        title: (j['title'] ?? '') as String,
        artist: (j['artist_names'] ?? (j['primary_artist'] as Map?)?['name'] ?? '') as String,
        url: (j['url'] ?? '') as String,
        thumbnail: j['song_art_image_thumbnail_url'] as String?,
        headerImage: (j['header_image_url'] ?? j['song_art_image_url']) as String?,
        description: description,
        annotationCount: (j['annotation_count'] as num?)?.toInt(),
      );
}

/// Genius API: metadata, artwork and the link to the page. (No lyrics text - see the plan's
/// legal notes.)
class GeniusClient {
  GeniusClient(this.http, {required this.token, this.base = 'https://api.genius.com'});

  final HttpService http;
  final String Function() token;
  final String base;

  bool get isConfigured => token().trim().isNotEmpty;

  Map<String, String> get _auth => {'Authorization': 'Bearer ${token().trim()}'};

  Future<List<GeniusSong>> search(String query) async {
    if (!isConfigured) return const [];
    final j = await http.getJson('$base/search', query: {'q': query}, headers: _auth, ttl: HttpService.mediumTtl);
    final hits = (((j['response'] as Map?)?['hits']) as List?) ?? const [];
    return [
      for (final h in hits)
        if ((h as Map)['type'] == 'song') GeniusSong.fromJson((h['result'] as Map).cast<String, dynamic>()),
    ];
  }

  Future<GeniusSong?> song(int id) async {
    if (!isConfigured) return null;
    final j = await http.getJsonOrNull('$base/songs/$id', query: {'text_format': 'plain'}, headers: _auth, ttl: HttpService.mediumTtl);
    final s = (j?['response'] as Map?)?['song'] as Map?;
    if (s == null) return null;
    final desc = ((s['description'] as Map?)?['plain']) as String?;
    return GeniusSong.fromJson(s.cast<String, dynamic>(), description: (desc == null || desc.trim() == '?') ? null : desc);
  }

  /// Best search hit for a track, or null.
  Future<GeniusSong?> match({required String title, String? artist}) async {
    final hits = await search('$title ${artist ?? ''}'.trim());
    GeniusSong? best;
    var bestScore = 0.0;
    for (final h in hits) {
      final score = StringSimilarity.ratio(title, h.title) * 0.6 + (artist == null ? 0.2 : StringSimilarity.ratio(artist, h.artist) * 0.4);
      if (score > bestScore) {
        bestScore = score;
        best = h;
      }
    }
    return bestScore >= 0.6 ? best : null;
  }
}
