import '../../core/models/track.dart';
import '../../core/net/http_service.dart';
import '../../core/settings/settings_store.dart';
import '../downloader/source_detect.dart';
import 'source_provider.dart';

/// Internet Archive: mostly public-domain / Creative Commons, including the Live Music
/// Archive - the legally safest source. Uses the Advanced Search + metadata APIs and plain
/// HTTP downloads (no yt-dlp needed).
class InternetArchiveSource extends SourceProvider {
  InternetArchiveSource(this.http, {this.preferLossless = false});

  final HttpService http;

  /// Prefer FLAC over VBR MP3 when both exist.
  final bool preferLossless;

  @override
  String get id => 'archive';

  @override
  String get label => 'Internet Archive';

  @override
  TrackSource get source => TrackSource.internetArchive;

  @override
  String? get note => 'Public domain and Creative Commons recordings, incl. the Live Music Archive.';

  @override
  bool canHandle(SourceInfo info) => info.source == TrackSource.internetArchive && info.id != null;

  static const _base = 'https://archive.org';

  @override
  Future<List<RemoteTrack>> search(String query, {int limit = 15}) async {
    final j = await http.getJson(
      '$_base/advancedsearch.php',
      query: {
        'q': '($query) AND mediatype:audio',
        'fl[]': ['identifier', 'title', 'creator', 'year', 'licenseurl'],
        'rows': limit,
        'output': 'json',
        'sort[]': 'downloads desc',
      },
      ttl: HttpService.shortTtl,
    );
    return parseSearch(j);
  }

  /// Parses an advancedsearch.php response.
  static List<RemoteTrack> parseSearch(dynamic j) {
    final docs = (((j as Map?)?['response'] as Map?)?['docs'] as List?) ?? const [];
    return [
      for (final d in docs)
        if ((d as Map)['identifier'] != null)
          RemoteTrack(
            id: d['identifier'] as String,
            provider: 'archive',
            source: TrackSource.internetArchive,
            title: _one(d['title']) ?? d['identifier'] as String,
            artist: _one(d['creator']),
            year: int.tryParse(_one(d['year']) ?? ''),
            pageUrl: 'https://archive.org/details/${d['identifier']}',
            isCollection: true,
            license: _one(d['licenseurl']),
          ),
    ];
  }

  static String? _one(Object? v) {
    if (v == null) return null;
    if (v is List) return v.isEmpty ? null : v.first.toString();
    final s = v.toString();
    return s.isEmpty ? null : s;
  }

  @override
  Future<RemoteTrack?> resolve(String url) async {
    final info = detectSource(url);
    if (info.id == null) return null;
    final j = await http.getJsonOrNull('$_base/metadata/${info.id}', ttl: HttpService.shortTtl);
    if (j == null) return null;
    final meta = ((j as Map)['metadata'] as Map?) ?? const {};
    return RemoteTrack(
      id: info.id!,
      provider: id,
      source: source,
      title: _one(meta['title']) ?? info.id!,
      artist: _one(meta['creator']),
      pageUrl: info.canonicalUrl,
      isCollection: true,
      license: _one(meta['licenseurl']),
      year: int.tryParse(_one(meta['year']) ?? ''),
    );
  }

  @override
  Future<List<RemoteTrack>> expand(RemoteTrack collection) async {
    final j = await http.getJson('$_base/metadata/${collection.id}', ttl: HttpService.shortTtl);
    return parseFiles(j, collection.id, preferLossless: preferLossless, fallbackArtist: collection.artist, fallbackAlbum: collection.title);
  }

  static const _losslessOrder = ['Flac', '24bit Flac', 'Ogg Vorbis', 'VBR MP3', '128Kbps MP3', 'MP3'];
  static const _lossyOrder = ['VBR MP3', 'MP3', '128Kbps MP3', 'Ogg Vorbis', 'Flac', '24bit Flac'];

  /// Turns an item's file list into one [RemoteTrack] per song, choosing one format each.
  static List<RemoteTrack> parseFiles(
    dynamic metadata,
    String identifier, {
    bool preferLossless = false,
    String? fallbackArtist,
    String? fallbackAlbum,
  }) {
    final m = metadata as Map;
    final meta = (m['metadata'] as Map?) ?? const {};
    final files = ((m['files'] as List?) ?? const []).cast<Map>();
    final order = preferLossless ? _losslessOrder : _lossyOrder;
    final artist = _one(meta['creator']) ?? fallbackArtist;
    final album = _one(meta['title']) ?? fallbackAlbum;
    final license = _one(meta['licenseurl']);

    // group files by base name (without extension) so FLAC + derived MP3 are one song
    final groups = <String, List<Map>>{};
    for (final f in files) {
      final format = f['format'] as String?;
      if (format == null || !order.contains(format)) continue;
      final name = f['name'] as String;
      final base = name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name;
      groups.putIfAbsent(base, () => []).add(f);
    }
    final tracks = <RemoteTrack>[];
    for (final e in groups.entries) {
      e.value.sort((a, b) => order.indexOf(a['format'] as String).compareTo(order.indexOf(b['format'] as String)));
      final f = e.value.first;
      final name = f['name'] as String;
      final length = f['length']?.toString();
      tracks.add(RemoteTrack(
        id: '$identifier/$name',
        provider: 'archive',
        source: TrackSource.internetArchive,
        title: (f['title'] as String?)?.trim().isNotEmpty == true ? f['title'] as String : e.key,
        artist: (f['creator'] as String?) ?? artist,
        album: (f['album'] as String?) ?? album,
        durationSec: _parseLength(length),
        pageUrl: 'https://archive.org/details/$identifier',
        downloadUrl: 'https://archive.org/download/$identifier/${Uri.encodeComponent(name)}',
        streamUrl: 'https://archive.org/download/$identifier/${Uri.encodeComponent(name)}',
        format: f['format'] as String?,
        sizeBytes: int.tryParse('${f['size']}'),
        trackNumber: int.tryParse('${f['track']}'.split('/').first),
        license: license,
      ));
    }
    tracks.sort((a, b) {
      final c = (a.trackNumber ?? 9999).compareTo(b.trackNumber ?? 9999);
      return c != 0 ? c : a.id.compareTo(b.id);
    });
    return tracks;
  }

  /// "153.5", "02:32" or "1:02:03" -> seconds.
  static int? _parseLength(String? s) {
    if (s == null || s.isEmpty) return null;
    if (s.contains(':')) {
      final parts = s.split(':').map((e) => double.tryParse(e) ?? 0).toList();
      var sec = 0.0;
      for (final p in parts) {
        sec = sec * 60 + p;
      }
      return sec.round();
    }
    return double.tryParse(s)?.round();
  }
}

/// Audius: open, decentralised music platform with a free public API.
class AudiusSource extends SourceProvider {
  AudiusSource(this.http, {this.appName = 'musicplayer'});

  final HttpService http;
  final String appName;
  String? _host;

  @override
  String get id => 'audius';

  @override
  String get label => 'Audius';

  @override
  TrackSource get source => TrackSource.audius;

  @override
  bool canHandle(SourceInfo info) => info.source == TrackSource.audius;

  /// Discovery: api.audius.co lists healthy hosts; pick one.
  Future<String> _discover() async {
    if (_host != null) return _host!;
    try {
      final j = await http.getJson('https://api.audius.co', ttl: HttpService.shortTtl);
      final hosts = ((j as Map)['data'] as List?)?.cast<String>() ?? const [];
      if (hosts.isNotEmpty) return _host = hosts.first;
    } on Exception {
      // fall through to the public gateway
    }
    return _host = 'https://api.audius.co';
  }

  @override
  Future<List<RemoteTrack>> search(String query, {int limit = 15}) async {
    final host = await _discover();
    final j = await http.getJson('$host/v1/tracks/search', query: {'query': query, 'limit': limit, 'app_name': appName}, ttl: HttpService.shortTtl);
    return parse(j, host, appName);
  }

  static List<RemoteTrack> parse(dynamic j, String host, String appName) {
    final data = ((j as Map?)?['data'] as List?) ?? const [];
    final out = <RemoteTrack>[];
    for (final t in data) {
      final m = t as Map;
      if (m['is_streamable'] == false || m['is_delete'] == true || m['is_unlisted'] == true) continue;
      final artwork = m['artwork'] as Map?;
      final user = m['user'] as Map?;
      final id = m['id'] as String;
      final streamUrl = '$host/v1/tracks/$id/stream?app_name=$appName';
      out.add(RemoteTrack(
        id: id,
        provider: 'audius',
        source: TrackSource.audius,
        title: (m['title'] ?? '') as String,
        artist: user?['name'] as String?,
        durationSec: (m['duration'] as num?)?.toInt(),
        thumbnail: (artwork?['480x480'] ?? artwork?['1000x1000'] ?? artwork?['150x150']) as String?,
        pageUrl: 'https://audius.co${m['permalink'] ?? ''}',
        streamUrl: streamUrl,
        downloadUrl: streamUrl,
        year: int.tryParse((m['release_date'] as String? ?? '').padRight(4).substring(0, 4).trim()),
        license: m['license'] as String?,
        extra: {'genre': m['genre']},
      ));
    }
    return out;
  }
}

/// Jamendo: Creative Commons music with an official API (free client id required).
class JamendoSource extends SourceProvider {
  JamendoSource(this.http, {required this.clientId});

  final HttpService http;
  final String Function() clientId;

  @override
  String get id => 'jamendo';

  @override
  String get label => 'Jamendo';

  @override
  TrackSource get source => TrackSource.jamendo;

  @override
  String? get note => 'Creative Commons music. Needs a free client id (Settings > Accounts).';

  @override
  bool canHandle(SourceInfo info) => false; // pages are not resolvable without the API

  bool get isConfigured => clientId().isNotEmpty;

  @override
  Future<List<RemoteTrack>> search(String query, {int limit = 15}) async {
    if (!isConfigured) return const [];
    final j = await http.getJson(
      'https://api.jamendo.com/v3.0/tracks/',
      query: {
        'client_id': clientId(),
        'format': 'json',
        'limit': limit,
        'search': query,
        'audioformat': 'mp32',
        'include': 'musicinfo',
        'imagesize': 500,
      },
      ttl: HttpService.shortTtl,
    );
    return parse(j);
  }

  static List<RemoteTrack> parse(dynamic j) {
    final results = ((j as Map?)?['results'] as List?) ?? const [];
    return [
      for (final r in results)
        RemoteTrack(
          id: '${(r as Map)['id']}',
          provider: 'jamendo',
          source: TrackSource.jamendo,
          title: (r['name'] ?? '') as String,
          artist: r['artist_name'] as String?,
          album: r['album_name'] as String?,
          durationSec: (r['duration'] as num?)?.toInt(),
          thumbnail: (r['image'] ?? r['album_image']) as String?,
          pageUrl: (r['shareurl'] ?? 'https://www.jamendo.com/track/${r['id']}') as String,
          streamUrl: r['audio'] as String?,
          downloadUrl: r['audiodownload_allowed'] == true ? r['audiodownload'] as String? : null,
          license: r['license_ccurl'] as String?,
          year: int.tryParse((r['releasedate'] as String? ?? '').padRight(4).substring(0, 4).trim()),
        ),
    ];
  }
}

/// ccMixter: Creative Commons remixes and a cappellas (query API returns JSON).
class CcMixterSource extends SourceProvider {
  CcMixterSource(this.http);

  final HttpService http;

  @override
  String get id => 'ccmixter';

  @override
  String get label => 'ccMixter';

  @override
  TrackSource get source => TrackSource.ccmixter;

  @override
  bool canHandle(SourceInfo info) => false;

  @override
  Future<List<RemoteTrack>> search(String query, {int limit = 15}) async {
    final j = await http.getJson(
      'https://ccmixter.org/api/query',
      query: {'f': 'json', 'search': query, 'limit': limit, 'sort': 'rank'},
      ttl: HttpService.shortTtl,
    );
    return parse(j);
  }

  static List<RemoteTrack> parse(dynamic j) {
    final out = <RemoteTrack>[];
    for (final u in (j as List?) ?? const []) {
      final m = u as Map;
      final files = ((m['files'] as List?) ?? const []).cast<Map>();
      Map? mp3;
      for (final f in files) {
        if ((f['file_format_info'] as Map?)?['default-ext'] == 'mp3') {
          mp3 = f;
          break;
        }
      }
      mp3 ??= files.isEmpty ? null : files.first;
      if (mp3 == null) continue;
      final ps = (mp3['file_format_info'] as Map?)?['ps'] as String?;
      out.add(RemoteTrack(
        id: '${m['upload_id']}',
        provider: 'ccmixter',
        source: TrackSource.ccmixter,
        title: (m['upload_name'] ?? '') as String,
        artist: (m['user_real_name'] ?? m['user_name']) as String?,
        durationSec: _seconds(ps),
        pageUrl: (m['file_page_url'] ?? '') as String,
        streamUrl: mp3['download_url'] as String?,
        downloadUrl: mp3['download_url'] as String?,
        license: m['license_url'] as String?,
        format: 'MP3',
      ));
    }
    return out;
  }

  static int? _seconds(String? ps) {
    if (ps == null || !ps.contains(':')) return null;
    final parts = ps.split(':').map((e) => int.tryParse(e) ?? 0).toList();
    var s = 0;
    for (final p in parts) {
      s = s * 60 + p;
    }
    return s;
  }
}

/// A bare link to an audio file. Nothing to look up: the file name is the title (the identify
/// step and the tag reader fill in the rest after the download).
class DirectFileSource extends SourceProvider {
  @override
  String get id => 'directfile';

  @override
  String get label => 'Direct file link';

  @override
  TrackSource get source => TrackSource.other;

  @override
  bool get supportsSearch => false;

  @override
  bool canHandle(SourceInfo info) => info.directAudio;

  @override
  Future<List<RemoteTrack>> search(String query, {int limit = 15}) async => const [];

  @override
  Future<RemoteTrack?> resolve(String url) async {
    final info = detectSource(url);
    final last = Uri.tryParse(info.canonicalUrl)?.pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? 'audio';
    final title = Uri.decodeComponent(last).replaceFirst(RegExp(r'\.[A-Za-z0-9]{2,4}$'), '').replaceAll('_', ' ').trim();
    return RemoteTrack(
      id: info.canonicalUrl,
      provider: id,
      source: TrackSource.other,
      title: title.isEmpty ? 'Audio file' : title,
      pageUrl: info.canonicalUrl,
      streamUrl: info.canonicalUrl,
      downloadUrl: info.canonicalUrl,
      extra: const {'titleGuess': true},
    );
  }
}

/// Which providers are switched on (Settings > Sources).
class SourceRegistry {
  SourceRegistry(this.settings, this.providers);

  final SettingsStore settings;
  final List<SourceProvider> providers;

  List<SourceProvider> get enabled => providers.where((p) => settings.isSourceEnabled(p.id)).toList();

  SourceProvider? byId(String id) {
    for (final p in providers) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// First enabled provider able to resolve [info] directly (yt-dlp is the fallback).
  SourceProvider? forUrl(SourceInfo info) {
    for (final p in enabled) {
      if (p.canHandle(info)) return p;
    }
    return null;
  }
}
