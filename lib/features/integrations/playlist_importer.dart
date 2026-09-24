import 'dart:convert';

import '../../core/library/library_repository.dart';
import '../../core/models/track.dart';
import '../../core/net/http_service.dart';
import '../../core/settings/settings_store.dart';
import '../../core/util/string_similarity.dart';
import '../downloader/download_manager.dart';
import '../downloader/engines.dart';
import '../metadata/title_cleaner.dart';
import '../sources/source_provider.dart';
import 'library_matcher.dart';
import 'metadata_clients.dart';
import 'wishlist.dart';

class ImportedPlaylist {
  const ImportedPlaylist({required this.name, required this.tracks, required this.origin});
  final String name;
  final List<WishTrack> tracks;
  final String origin; // spotify | deezer | youtube
}

class ImportPlan {
  const ImportPlan({required this.playlist, required this.matched, required this.missing});
  final ImportedPlaylist playlist;
  final List<({WishTrack wanted, Track local})> matched;
  final List<WishTrack> missing;
}

class UnsupportedPlaylistUrl implements Exception {
  @override
  String toString() => 'Paste a Spotify, Deezer or YouTube playlist link.';
}

/// Paste a Spotify / Deezer / YouTube playlist URL -> match every track against the library ->
/// create a local playlist from what exists and put the rest on the wishlist (plan 7.3).
class PlaylistImporter {
  PlaylistImporter({
    required this.http,
    required this.repo,
    required this.settings,
    required this.deezer,
    required this.engine,
    required this.wishlist,
  }) : matcher = LibraryMatcher(repo);

  final HttpService http;
  final LibraryRepository repo;
  final SettingsStore settings;
  final DeezerClient deezer;
  final DownloadEngine Function() engine;
  final WishlistRepository wishlist;
  final LibraryMatcher matcher;

  static String? spotifyId(String url) =>
      RegExp(r'(?:open\.spotify\.com/(?:intl-[a-z]+/)?playlist/|spotify:playlist:)([A-Za-z0-9]+)').firstMatch(url)?.group(1);

  static String? deezerId(String url) => RegExp(r'deezer\.com/(?:[a-z]{2}/)?playlist/(\d+)').firstMatch(url)?.group(1);

  static bool isYouTubePlaylist(String url) => RegExp(r'[?&]list=[A-Za-z0-9_-]+').hasMatch(url) && url.contains('youtube.com');

  Future<ImportedPlaylist> fetch(String url) async {
    final sp = spotifyId(url);
    if (sp != null) return _spotify(sp);
    final dz = deezerId(url);
    if (dz != null) {
      final p = await deezer.playlist(dz);
      return ImportedPlaylist(name: p.name, tracks: p.tracks, origin: 'deezer');
    }
    if (isYouTubePlaylist(url)) {
      final list = await engine().listPlaylist(url);
      final cleaner = TitleCleaner.fromSettings(settings.titleRules);
      return ImportedPlaylist(
        name: list.title,
        origin: 'youtube',
        tracks: [
          for (final e in list.entries)
            () {
              final c = cleaner.clean(e.track ?? e.title, uploader: e.uploader);
              return WishTrack(artist: e.artist ?? c.artist ?? TitleCleaner.cleanChannel(e.uploader ?? ''), title: c.title, album: e.album, durationMs: (e.durationSec ?? 0) * 1000);
            }(),
        ],
      );
    }
    throw UnsupportedPlaylistUrl();
  }

  Future<String> _spotifyToken() async {
    final id = settings.spotifyClientId, secret = settings.spotifyClientSecret;
    if (id.isEmpty || secret.isEmpty) {
      throw StateError('Spotify import needs a client id and secret (Settings > Accounts).');
    }
    final j = await http.postForm(
      'https://accounts.spotify.com/api/token',
      fields: {'grant_type': 'client_credentials'},
      headers: {'Authorization': 'Basic ${base64.encode(utf8.encode('$id:$secret'))}'},
    );
    return (j as Map)['access_token'] as String;
  }

  Future<ImportedPlaylist> _spotify(String id) async {
    final token = await _spotifyToken();
    final headers = {'Authorization': 'Bearer $token'};
    final meta = await http.getJsonOrNull('https://api.spotify.com/v1/playlists/$id', query: {'fields': 'name'}, headers: headers);
    final tracks = <WishTrack>[];
    String? next = 'https://api.spotify.com/v1/playlists/$id/tracks?limit=100&fields=items(track(name,duration_ms,external_ids,artists(name),album(name))),next';
    var pages = 0;
    while (next != null && pages++ < 30) {
      final j = await http.getJson(next, headers: headers) as Map;
      tracks.addAll(parseSpotifyItems(j));
      next = j['next'] as String?;
    }
    return ImportedPlaylist(name: (meta as Map?)?['name'] as String? ?? 'Spotify playlist', tracks: tracks, origin: 'spotify');
  }

  /// Parses `items[].track` of a Spotify playlist page (skips removed/local entries).
  static List<WishTrack> parseSpotifyItems(Map j) => [
        for (final it in (j['items'] as List?) ?? const [])
          if ((it as Map)['track'] is Map)
            WishTrack(
              artist: ((it['track']['artists'] as List?) ?? const []).map((a) => (a as Map)['name'] as String).join(', '),
              title: it['track']['name'] as String,
              album: (it['track']['album'] as Map?)?['name'] as String?,
              isrc: (it['track']['external_ids'] as Map?)?['isrc'] as String?,
              durationMs: (it['track']['duration_ms'] as num?)?.toInt(),
            ),
      ];

  Future<ImportPlan> plan(ImportedPlaylist playlist) async {
    final matched = <({WishTrack wanted, Track local})>[];
    final missing = <WishTrack>[];
    for (final w in playlist.tracks) {
      final t = await matcher.find(artist: w.artist, title: w.title, durationMs: w.durationMs);
      if (t != null) {
        matched.add((wanted: w, local: t));
      } else {
        missing.add(w);
      }
    }
    return ImportPlan(playlist: playlist, matched: matched, missing: missing);
  }

  /// Creates the playlist from matches and wishlists the rest. Returns the playlist id.
  Future<int> commit(ImportPlan plan, {String? name}) async {
    final id = await repo.createPlaylist(name ?? plan.playlist.name);
    await repo.addToPlaylist(id, plan.matched.map((m) => m.local.id));
    for (final w in plan.missing) {
      await wishlist.add(w, origin: plan.playlist.origin);
    }
    return id;
  }
}

/// Turns wishlist entries into downloads by finding the best search result.
class WishlistDownloader {
  WishlistDownloader({required this.wishlist, required this.manager, required this.providers});

  final WishlistRepository wishlist;
  final DownloadManager manager;

  /// Providers to try, in order (YouTube Music first: cleanest metadata).
  final List<SourceProvider> providers;

  /// Picks the search result closest to what was asked for: title + artist similarity, duration.
  static RemoteTrack? bestResult(WishTrack wanted, List<RemoteTrack> results) {
    RemoteTrack? best;
    var bestScore = 0.0;
    for (final r in results) {
      if (r.isCollection) continue;
      final title = StringSimilarity.ratio(wanted.title, r.title);
      final artist = StringSimilarity.ratio(wanted.artist, r.artist ?? '');
      final inTitle = r.title.toLowerCase().contains(wanted.artist.toLowerCase()) ? 0.15 : 0.0;
      var score = title * 0.55 + (artist > inTitle ? artist : inTitle) * 0.3;
      if (wanted.durationMs != null && wanted.durationMs! > 0 && r.durationSec != null) {
        final diff = (wanted.durationMs! / 1000 - r.durationSec!).abs();
        score += diff <= 3 ? 0.15 : diff <= 10 ? 0.05 : -0.1;
      }
      if (score > bestScore) {
        bestScore = score;
        best = r;
      }
    }
    return bestScore >= 0.55 ? best : null;
  }

  /// Returns true when a download was queued.
  Future<bool> download(int wishId, WishTrack wanted) async {
    for (final p in providers) {
      try {
        final results = await p.search('${wanted.artist} ${wanted.title}', limit: 8);
        final best = bestResult(wanted, results);
        if (best == null) continue;
        final r = await manager.enqueueRemote(best);
        await wishlist.setStatus(wishId, r.duplicate != null ? 'done' : 'downloading', jobId: r.jobId);
        return true;
      } on Exception {
        continue;
      }
    }
    await wishlist.setStatus(wishId, 'notfound');
    return false;
  }
}
