import 'dart:convert';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;
import 'package:xml/xml.dart';

import '../../core/db/app_database.dart';
import '../../core/models/track.dart';
import '../../core/net/http_service.dart';
import '../../core/settings/settings_store.dart';
import '../playback/media_items.dart';
import 'source_provider.dart';

class PodcastFeed {
  const PodcastFeed({required this.title, required this.feedUrl, this.author, this.imageUrl, this.description});
  final String title;
  final String feedUrl;
  final String? author;
  final String? imageUrl;
  final String? description;
}

class PodcastEpisode {
  const PodcastEpisode({
    required this.title,
    required this.audioUrl,
    required this.podcast,
    required this.feedUrl,
    this.guid,
    this.mimeType,
    this.sizeBytes,
    this.duration,
    this.published,
    this.description,
    this.imageUrl,
  });

  final String title;
  final String audioUrl;
  final String podcast;
  final String feedUrl;
  final String? guid;
  final String? mimeType;
  final int? sizeBytes;
  final Duration? duration;
  final DateTime? published;
  final String? description;
  final String? imageUrl;

  MediaItem toMediaItem() => MediaItem(
        id: audioUrl,
        title: title,
        artist: podcast,
        album: podcast,
        duration: duration,
        artUri: imageUrl == null ? null : Uri.tryParse(imageUrl!),
        extras: {
          MediaExtras.remote: true,
          MediaExtras.isPodcast: true,
          MediaExtras.sourceUrl: audioUrl,
          MediaExtras.source: TrackSource.podcast.name,
          if (imageUrl != null) MediaExtras.thumbnail: imageUrl,
        },
      );

  RemoteTrack toRemoteTrack() => RemoteTrack(
        id: guid ?? audioUrl,
        provider: 'podcast',
        source: TrackSource.podcast,
        title: title,
        artist: podcast,
        album: podcast,
        durationSec: duration?.inSeconds,
        thumbnail: imageUrl,
        pageUrl: feedUrl,
        streamUrl: audioUrl,
        downloadUrl: audioUrl,
        year: published?.year,
        sizeBytes: sizeBytes,
      );
}

/// Podcasts: search (iTunes, no key - or Podcast Index with a key), RSS parsing, subscriptions.
class PodcastService {
  PodcastService({required this.http, required this.appDb, required this.settings, DateTime Function()? now}) : _now = now ?? DateTime.now;

  final HttpService http;
  final AppDatabase appDb;
  final SettingsStore settings;
  final DateTime Function() _now;

  Future<List<PodcastFeed>> search(String query) async {
    final feeds = <PodcastFeed>[];
    if (settings.podcastIndexKey.isNotEmpty && settings.podcastIndexSecret.isNotEmpty) {
      try {
        final date = '${_now().millisecondsSinceEpoch ~/ 1000}';
        final auth = sha1.convert(utf8.encode('${settings.podcastIndexKey}${settings.podcastIndexSecret}$date')).toString();
        final j = await http.getJson(
          'https://api.podcastindex.org/api/1.0/search/byterm',
          query: {'q': query, 'max': 20},
          headers: {'X-Auth-Date': date, 'X-Auth-Key': settings.podcastIndexKey, 'Authorization': auth},
          ttl: HttpService.shortTtl,
        );
        for (final f in ((j as Map)['feeds'] as List?) ?? const []) {
          final m = f as Map;
          feeds.add(PodcastFeed(title: (m['title'] ?? '') as String, feedUrl: (m['url'] ?? '') as String, author: m['author'] as String?, imageUrl: (m['image'] ?? m['artwork']) as String?, description: m['description'] as String?));
        }
      } on Exception {
        // fall back to iTunes below
      }
    }
    if (feeds.isEmpty) {
      final j = await http.getJson('https://itunes.apple.com/search', query: {'media': 'podcast', 'term': query, 'limit': 20}, ttl: HttpService.shortTtl);
      for (final r in ((j as Map)['results'] as List?) ?? const []) {
        final m = r as Map;
        if (m['feedUrl'] == null) continue;
        feeds.add(PodcastFeed(
          title: (m['collectionName'] ?? m['trackName'] ?? '') as String,
          feedUrl: m['feedUrl'] as String,
          author: m['artistName'] as String?,
          imageUrl: (m['artworkUrl600'] ?? m['artworkUrl100']) as String?,
        ));
      }
    }
    return feeds;
  }

  Future<({PodcastFeed feed, List<PodcastEpisode> episodes})> fetch(String feedUrl) async {
    final xml = await http.getText(feedUrl, ttl: const Duration(minutes: 20), headers: {'Accept': 'application/rss+xml, application/xml, text/xml, */*'});
    return parseFeed(xml, feedUrl);
  }

  // ------------------------------------------------------------- RSS parsing

  static ({PodcastFeed feed, List<PodcastEpisode> episodes}) parseFeed(String source, String feedUrl) {
    final doc = XmlDocument.parse(source.trimLeft());
    final channel = doc.findAllElements('channel').first;
    String? text(XmlElement e, String name) {
      final t = e.getElement(name)?.innerText.trim();
      return (t == null || t.isEmpty) ? null : t;
    }

    String? itunesImage(XmlElement e) {
      for (final img in e.findElements('itunes:image')) {
        final href = img.getAttribute('href');
        if (href != null && href.isNotEmpty) return href;
      }
      return e.getElement('image')?.getElement('url')?.innerText.trim();
    }

    final podcast = text(channel, 'title') ?? 'Podcast';
    final feed = PodcastFeed(
      title: podcast,
      feedUrl: feedUrl,
      author: text(channel, 'itunes:author') ?? text(channel, 'author'),
      imageUrl: itunesImage(channel),
      description: text(channel, 'description'),
    );
    final episodes = <PodcastEpisode>[];
    for (final item in channel.findElements('item')) {
      final enclosure = item.getElement('enclosure');
      final url = enclosure?.getAttribute('url');
      if (url == null || url.isEmpty) continue;
      episodes.add(PodcastEpisode(
        title: text(item, 'title') ?? 'Episode',
        audioUrl: url,
        podcast: podcast,
        feedUrl: feedUrl,
        guid: text(item, 'guid'),
        mimeType: enclosure!.getAttribute('type'),
        sizeBytes: int.tryParse(enclosure.getAttribute('length') ?? ''),
        duration: parseItunesDuration(text(item, 'itunes:duration')),
        published: parseRfc822(text(item, 'pubDate')),
        description: text(item, 'description'),
        imageUrl: itunesImage(item) ?? feed.imageUrl,
      ));
    }
    return (feed: feed, episodes: episodes);
  }

  /// "1:02:03", "45:10" or "3671" (seconds).
  static Duration? parseItunesDuration(String? s) {
    if (s == null || s.isEmpty) return null;
    final parts = s.split(':').map((e) => double.tryParse(e.trim())).toList();
    if (parts.any((e) => e == null)) return null;
    var seconds = 0.0;
    for (final p in parts) {
      seconds = seconds * 60 + p!;
    }
    return Duration(seconds: seconds.round());
  }

  static const _months = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];

  /// "Wed, 02 Oct 2002 13:00:00 GMT" (also without weekday / with +0200 offsets).
  static DateTime? parseRfc822(String? s) {
    if (s == null) return null;
    final m = RegExp(r'(\d{1,2})\s+([A-Za-z]{3})[a-z]*\s+(\d{4})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([+-]\d{4}|[A-Z]{1,4})?').firstMatch(s);
    if (m == null) return null;
    final month = _months.indexOf(m.group(2)!.toLowerCase()) + 1;
    if (month == 0) return null;
    var dt = DateTime.utc(int.parse(m.group(3)!), month, int.parse(m.group(1)!), int.parse(m.group(4)!), int.parse(m.group(5)!), int.tryParse(m.group(6) ?? '0') ?? 0);
    final tz = m.group(7);
    if (tz != null && RegExp(r'^[+-]\d{4}$').hasMatch(tz)) {
      final sign = tz.startsWith('-') ? -1 : 1;
      final off = Duration(hours: int.parse(tz.substring(1, 3)), minutes: int.parse(tz.substring(3, 5)));
      dt = sign > 0 ? dt.subtract(off) : dt.add(off);
    }
    return dt;
  }

  // ------------------------------------------------------------ subscriptions

  Future<List<PodcastFeed>> subscriptions() async {
    final rows = await appDb.db.query('podcast_feeds', orderBy: 'title COLLATE NOCASE');
    return [
      for (final r in rows)
        PodcastFeed(title: r['title'] as String, feedUrl: r['feed_url'] as String, author: r['author'] as String?, imageUrl: r['image_url'] as String?),
    ];
  }

  Future<bool> isSubscribed(String feedUrl) async =>
      (await appDb.db.query('podcast_feeds', columns: ['id'], where: 'feed_url = ?', whereArgs: [feedUrl], limit: 1)).isNotEmpty;

  Future<void> subscribe(PodcastFeed f) async {
    await appDb.db.insert('podcast_feeds', {'title': f.title, 'feed_url': f.feedUrl, 'image_url': f.imageUrl, 'author': f.author}, conflictAlgorithm: ConflictAlgorithm.ignore);
    appDb.notifyChanged();
  }

  Future<void> unsubscribe(String feedUrl) async {
    await appDb.db.delete('podcast_feeds', where: 'feed_url = ?', whereArgs: [feedUrl]);
    appDb.notifyChanged();
  }
}

class RadioStation {
  const RadioStation({required this.uuid, required this.name, required this.url, this.favicon, this.country, this.codec, this.bitrate, this.tags = const []});

  final String uuid;
  final String name;
  final String url;
  final String? favicon;
  final String? country;
  final String? codec;
  final int? bitrate;
  final List<String> tags;

  factory RadioStation.fromJson(Map<String, dynamic> j) => RadioStation(
        uuid: (j['stationuuid'] ?? '') as String,
        name: ((j['name'] ?? '') as String).trim(),
        url: ((j['url_resolved'] as String?)?.isNotEmpty == true ? j['url_resolved'] : j['url']) as String,
        favicon: (j['favicon'] as String?)?.isEmpty == true ? null : j['favicon'] as String?,
        country: j['country'] as String?,
        codec: j['codec'] as String?,
        bitrate: (j['bitrate'] as num?)?.toInt(),
        tags: ((j['tags'] as String?) ?? '').split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
      );

  MediaItem toMediaItem() => MediaItem(
        id: url,
        title: name,
        artist: [if (country != null && country!.isNotEmpty) country, if (tags.isNotEmpty) tags.take(2).join(', ')].join(' - '),
        artUri: favicon == null ? null : Uri.tryParse(favicon!),
        extras: {MediaExtras.remote: true, MediaExtras.isRadio: true, 'station': name, MediaExtras.sourceUrl: url},
      );
}

/// Radio Browser (community directory, no key). Servers are discovered, then one is picked.
class RadioBrowserClient {
  RadioBrowserClient(this.http, this.appDb, {Random? random}) : _random = random ?? Random();

  final HttpService http;
  final AppDatabase appDb;
  final Random _random;
  String? _host;

  static const String fallbackHost = 'https://de1.api.radio-browser.info';

  Future<String> _server() async {
    if (_host != null) return _host!;
    try {
      final j = await http.getJson('https://all.api.radio-browser.info/json/servers', ttl: HttpService.mediumTtl);
      final names = {for (final s in (j as List)) (s as Map)['name'] as String}.toList();
      if (names.isNotEmpty) return _host = 'https://${names[_random.nextInt(names.length)]}';
    } on Exception {
      // use the fallback
    }
    return _host = fallbackHost;
  }

  Future<List<RadioStation>> search({String? name, String? tag, String? country, int limit = 30}) async {
    final host = await _server();
    final j = await http.getJson(
      '$host/json/stations/search',
      query: {
        if (name != null && name.isNotEmpty) 'name': name,
        if (tag != null && tag.isNotEmpty) 'tag': tag,
        if (country != null && country.isNotEmpty) 'country': country,
        'limit': limit,
        'hidebroken': 'true',
        'order': 'clickcount',
        'reverse': 'true',
      },
      ttl: HttpService.shortTtl,
    );
    return [
      for (final s in (j as List))
        if ((s as Map)['lastcheckok'] != 0) RadioStation.fromJson(s.cast<String, dynamic>()),
    ];
  }

  Future<List<Map<String, dynamic>>> tags({int limit = 40}) async {
    final host = await _server();
    final j = await http.getJson('$host/json/tags', query: {'order': 'stationcount', 'reverse': 'true', 'limit': limit, 'hidebroken': 'true'}, ttl: HttpService.mediumTtl);
    return [for (final t in (j as List)) (t as Map).cast<String, dynamic>()];
  }

  /// Courtesy click count so popular stations rank higher for everyone.
  Future<void> registerClick(String uuid) async {
    try {
      final host = await _server();
      await http.getJson('$host/json/url/$uuid');
    } on Exception {
      // best effort
    }
  }

  // ---------------------------------------------------------------- favorites

  Future<List<RadioStation>> favorites() async {
    final rows = await appDb.db.query('radio_favorites', orderBy: 'name COLLATE NOCASE');
    return [
      for (final r in rows)
        RadioStation(
          uuid: (r['station_uuid'] ?? '') as String,
          name: r['name'] as String,
          url: r['stream_url'] as String,
          favicon: r['favicon'] as String?,
          country: r['country'] as String?,
          tags: ((r['tags'] as String?) ?? '').split(',').where((e) => e.isNotEmpty).toList(),
        ),
    ];
  }

  Future<bool> isFavorite(String url) async =>
      (await appDb.db.query('radio_favorites', columns: ['id'], where: 'stream_url = ?', whereArgs: [url], limit: 1)).isNotEmpty;

  Future<void> addFavorite(RadioStation s) async {
    await appDb.db.insert('radio_favorites', {'station_uuid': s.uuid, 'name': s.name, 'stream_url': s.url, 'favicon': s.favicon, 'country': s.country, 'tags': s.tags.join(',')}, conflictAlgorithm: ConflictAlgorithm.ignore);
    appDb.notifyChanged();
  }

  Future<void> removeFavorite(String url) async {
    await appDb.db.delete('radio_favorites', where: 'stream_url = ?', whereArgs: [url]);
    appDb.notifyChanged();
  }
}
