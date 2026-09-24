import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/db/app_database.dart';
import '../core/library/library_repository.dart';
import '../core/net/api_cache.dart';
import '../core/net/http_service.dart';
import '../core/settings/settings_store.dart';
import '../features/cover/cover_providers.dart';
import '../features/cover/cover_service.dart';
import '../features/downloader/download_manager.dart';
import '../features/downloader/download_pipeline.dart';
import '../features/downloader/engines.dart';
import '../features/downloader/job_repository.dart';
import '../features/integrations/artist_info_service.dart';
import '../features/integrations/lastfm_client.dart';
import '../features/integrations/listenbrainz_client.dart';
import '../features/integrations/metadata_clients.dart';
import '../features/integrations/playlist_importer.dart';
import '../features/integrations/radio_service.dart';
import '../features/integrations/release_watcher.dart';
import '../features/integrations/scrobble_service.dart';
import '../features/integrations/wishlist.dart';
import '../features/library/library_editor.dart';
import '../features/library/library_scanner.dart';
import '../features/lyrics/lyrics_clients.dart';
import '../features/lyrics/lyrics_service.dart';
import '../features/metadata/acoustid_client.dart';
import '../features/metadata/fingerprint_service.dart';
import '../features/metadata/identify_service.dart';
import '../features/metadata/musicbrainz_client.dart';
import '../features/metadata/tag_writer.dart';
import '../features/playback/audio_handler.dart';
import '../features/playback/loudness_service.dart';
import '../features/playback/media_items.dart';
import '../features/playback/player_facade.dart';
import '../features/sources/direct_sources.dart';
import '../features/sources/podcast_radio.dart';
import '../features/sources/unified_search.dart';
import '../features/sources/ytdlp_source.dart';
import '../platform/bridges.dart';
import 'cover_cache.dart';

/// Resolves page URLs (YouTube, SoundCloud) to short-lived stream URLs for playback.
class EngineStreamResolver implements StreamResolver {
  EngineStreamResolver(this.router);

  final EngineRouter router;
  final Map<String, ({Uri url, DateTime at})> _cache = {};

  @override
  Future<Uri> resolveStream(String pageUrl) async {
    final hit = _cache[pageUrl];
    if (hit != null && DateTime.now().difference(hit.at) < const Duration(minutes: 20)) return hit.url;
    final url = await router.current.streamUrl(pageUrl);
    _cache[pageUrl] = (url: url, at: DateTime.now());
    return url;
  }

  void forget(String pageUrl) => _cache.remove(pageUrl);
}

/// Every service the UI needs, wired once at startup (a small hand-written service locator).
class AppServices {
  AppServices._();

  late final SettingsStore settings;
  late final AppDatabase db;
  late final LibraryRepository repo;
  late final JobRepository jobs;
  late final Bridges bridges;
  late final HttpService http;
  late final ApiCache apiCache;
  late final Directory supportDir;
  late final Directory cacheDir;

  late final MusicAudioHandler handler;
  late final PlayerFacade player;
  late final LibraryScanner scanner;

  late final TagWriter tagWriter;
  late final CoverService covers;
  late final CoverCache coverCache;
  late final IdentifyService identify;
  late final LyricsService lyrics;
  late final LoudnessService loudness;
  late final ArtistInfoService artistInfo;
  late final LibraryEditor editor;

  late final EngineRouter engines;
  late final DownloadManager downloads;
  late final SourceRegistry sources;
  late final UnifiedSearch search;

  late final LastFmClient lastFm;
  late final ListenBrainzClient listenBrainz;
  late final ScrobbleService scrobble;
  late final RadioService radio;
  late final PodcastService podcasts;
  late final RadioBrowserClient radioStations;
  late final WishlistRepository wishlist;
  late final PlaylistImporter importer;
  late final WishlistDownloader wishDownloader;
  late final ReleaseWatcher releaseWatcher;
  late final GeniusClient genius;

  static Future<AppServices> create({bool startAudio = true}) async {
    final s = AppServices._();
    s.settings = await SettingsStore.load();
    s.supportDir = await getApplicationSupportDirectory();
    s.cacheDir = await getTemporaryDirectory();
    s.db = await AppDatabase.open();
    s.repo = LibraryRepository(s.db);
    s.jobs = JobRepository(s.db);
    s.bridges = Bridges();
    s.apiCache = DbApiCache(s.db);
    s.http = HttpService(userAgent: () => s.settings.userAgent, cache: s.apiCache);
    s.tagWriter = TagWriter(repo: s.repo, bridges: s.bridges);

    // --- metadata / covers / lyrics ---------------------------------------------
    final mb = MusicBrainzClient(s.http);
    final acoustId = AcoustIdClient(s.http, apiKey: () => s.settings.acoustIdKey);
    Directory sub(String name) => Directory('${s.supportDir.path}/$name')..createSync(recursive: true);
    final fingerprints = FingerprintService(decoder: s.bridges.decoder, tempDir: () => Directory('${s.cacheDir.path}/fp'));
    s.identify = IdentifyService(
      repo: s.repo,
      settings: s.settings,
      musicBrainz: mb,
      acoustId: acoustId,
      fingerprints: fingerprints,
      tagWriter: s.tagWriter,
      bridges: s.bridges,
    );
    s.covers = CoverService(
      repo: s.repo,
      http: s.http,
      bridges: s.bridges,
      settings: s.settings,
      providers: {
        'caa': CoverArtArchiveProvider(s.http),
        'caa-group': CoverArtArchiveProvider(s.http, byReleaseGroup: true),
        'itunes': ITunesCoverProvider(s.http),
        'deezer': DeezerCoverProvider(s.http),
        'lastfm': LastFmCoverProvider(s.http, apiKey: () => s.settings.lastFmKey),
      },
      tagWriter: s.tagWriter,
      coversDir: () => sub('covers'),
    );
    s.coverCache = CoverCache(repo: s.repo, covers: s.covers);
    s.genius = GeniusClient(s.http, token: () => s.settings.geniusToken);
    s.lyrics = LyricsService(
      repo: s.repo,
      bridges: s.bridges,
      settings: s.settings,
      lrclib: LrclibClient(s.http),
      genius: s.genius,
      tagWriter: s.tagWriter,
    );
    s.loudness = LoudnessService(repo: s.repo, decoder: s.bridges.decoder, tagWriter: s.tagWriter, tempDir: () => Directory('${s.cacheDir.path}/rg'));

    // --- integrations ------------------------------------------------------------------
    s.lastFm = LastFmClient(s.http,
        apiKey: () => s.settings.lastFmKey, apiSecret: () => s.settings.lastFmSecret, sessionKey: () => s.settings.lastFmSession);
    s.listenBrainz = ListenBrainzClient(s.http, token: () => s.settings.listenBrainzToken);
    s.scrobble = ScrobbleService(appDb: s.db, settings: s.settings, lastFm: s.lastFm, listenBrainz: s.listenBrainz);
    s.radio = RadioService(repo: s.repo, settings: s.settings, lastFm: s.lastFm, listenBrainz: s.listenBrainz);
    s.podcasts = PodcastService(http: s.http, appDb: s.db, settings: s.settings);
    s.radioStations = RadioBrowserClient(s.http, s.db);
    s.wishlist = WishlistRepository(s.db);
    s.artistInfo = ArtistInfoService(
      repo: s.repo,
      http: s.http,
      musicBrainz: mb,
      fanart: FanartClient(s.http, apiKey: () => s.settings.fanartKey),
      audioDb: AudioDbClient(s.http, apiKey: () => s.settings.audioDbKey),
      wiki: WikiClient(s.http),
      deezer: DeezerClient(s.http),
      lastFm: s.lastFm,
      imagesDir: () => sub('artists'),
    );
    s.editor = LibraryEditor(repo: s.repo, tagWriter: s.tagWriter, settings: s.settings, imagesDir: () => sub('artists'));

    // --- downloads ------------------------------------------------------------------------
    final local = LocalYtDlpEngine(s.bridges.ytDlp, s.settings);
    final server = ServerYtDlpEngine(s.http, baseUrl: () => s.settings.serverUrl, token: () => s.settings.serverToken);
    s.engines = EngineRouter(settings: s.settings, local: local, server: server, direct: DirectHttpEngine(s.http));
    s.sources = SourceRegistry(s.settings, [
      ...ytDlpProviders(() => s.engines.current),
      InternetArchiveSource(s.http),
      AudiusSource(s.http),
      JamendoSource(s.http, clientId: () => s.settings.jamendoClientId),
      CcMixterSource(s.http),
      DirectFileSource(),
    ]);
    s.search = UnifiedSearch(repo: s.repo, settings: s.settings, registry: s.sources);
    final pipeline = DownloadPipeline(
      repo: s.repo,
      jobs: s.jobs,
      bridges: s.bridges,
      settings: s.settings,
      identify: s.identify,
      covers: s.covers,
      lyrics: s.lyrics,
      loudness: s.loudness,
    );
    s.downloads = DownloadManager(
      repo: s.repo,
      jobs: s.jobs,
      settings: s.settings,
      router: s.engines,
      pipeline: pipeline,
      bridges: s.bridges,
      network: ConnectivityNetworkGuard(),
      tempDir: () => s.cacheDir,
    );
    s.importer = PlaylistImporter(
      http: s.http,
      repo: s.repo,
      settings: s.settings,
      deezer: DeezerClient(s.http),
      engine: () => s.engines.current,
      wishlist: s.wishlist,
    );
    s.wishDownloader = WishlistDownloader(
      wishlist: s.wishlist,
      manager: s.downloads,
      providers: [
        for (final id in const ['youtubemusic', 'youtube'])
          if (s.sources.byId(id) != null) s.sources.byId(id)!,
      ],
    );
    s.releaseWatcher = ReleaseWatcher(repo: s.repo, musicBrainz: mb, system: s.bridges.system);

    // --- library + playback ----------------------------------------------------------------
    s.scanner = LibraryScanner(repo: s.repo, bridges: s.bridges, settings: s.settings);
    if (startAudio) {
      s.handler = await AudioService.init(
        builder: () => MusicAudioHandler(
          repo: s.repo,
          settings: s.settings,
          artwork: s.covers,
          streams: EngineStreamResolver(s.engines),
          onPlayCounted: (item, eligible) {
            final id = item.trackId;
            if (id != null) s.repo.recordPlay(id);
            if (eligible && item.artist != null && !item.isRadio) {
              s.scrobble.record(
                ScrobbleItem(
                  artist: item.artist!,
                  title: item.title,
                  album: item.album,
                  durationSec: item.duration?.inSeconds,
                  timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000 - (item.duration?.inSeconds ?? 0) ~/ 2,
                  mbid: item.extras?[MediaExtras.mbRecordingId] as String?,
                ),
                trackId: id,
              );
            }
          },
          onNowPlaying: (item) {
            if (item.artist != null && !item.isRadio && item.trackId != null) {
              s.scrobble.nowPlaying(ScrobbleItem(
                artist: item.artist!,
                title: item.title,
                album: item.album,
                durationSec: item.duration?.inSeconds,
                timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
              ));
            }
          },
        ),
        config: AudioServiceConfig(
          androidNotificationChannelId: 'dev.personal.musicplayer.playback',
          androidNotificationChannelName: 'Playback',
          androidNotificationIcon: 'drawable/ic_stat_music',
          androidNotificationOngoing: false,
          androidStopForegroundOnPause: true,
          androidBrowsableRootExtras: const {
            'android.media.browse.CONTENT_STYLE_SUPPORTED': true,
            'android.media.browse.CONTENT_STYLE_BROWSABLE_HINT': 2,
            'android.media.browse.CONTENT_STYLE_PLAYABLE_HINT': 1,
          },
        ),
      );
      s.player = HandlerPlayerFacade(s.handler);
    }
    return s;
  }

  /// Post-startup work that must not block the first frame.
  Future<void> start({bool hasLibraryPermission = false}) async {
    try {
      await handlerRestore();
      await downloads.start();
      unawaited(apiCache.purgeExpired());
      if (hasLibraryPermission) {
        scanner.startWatching();
        unawaited(scanner.scan());
      }
      unawaited(_periodic());
    } on Object catch (e, st) {
      if (kDebugMode) debugPrint('startup task failed: $e\n$st');
    }
  }

  Future<void> handlerRestore() async {
    try {
      await handler.restoreQueue();
    } on Object {
      // a corrupt saved queue must never block startup
    }
  }

  /// Daily-ish housekeeping: yt-dlp update, scrobble flush, release alerts.
  Future<void> _periodic() async {
    try {
      if (isAndroid && settings.autoUpdateYtDlp && settings.isDue('ytdlp-update', const Duration(days: 7))) {
        await settings.markRun('ytdlp-update');
        try {
          await engines.local.update(settings.ytDlpChannel);
          await settings.setLastYtDlpUpdate(DateTime.now());
        } on Object {
          await settings.markRun('ytdlp-update', DateTime.now().subtract(const Duration(days: 6)));
        }
      }
      unawaited(scrobble.flush());
      if (settings.isDue('release-watch', const Duration(hours: 20))) {
        await settings.markRun('release-watch');
        await releaseWatcher.checkAll();
      }
    } on Object {
      // best effort
    }
  }

  Future<void> dispose() async {
    downloads.dispose();
    coverCache.dispose();
    scrobble.dispose();
    await scanner.dispose();
    await db.close();
  }
}
