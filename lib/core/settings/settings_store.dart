import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';

/// `amoled` is kept so older settings still load; it now means dark + [SettingsStore.pureBlack].
enum ThemePreference { system, light, dark, amoled }

/// Colour palettes: each tints the app's paper and ink and sets its single accent.
/// `custom` is built from [SettingsStore.customHue] and [SettingsStore.customTint].
enum AppPalette { green, coral, sage, ocean, amber, rose, violet, ink, custom }

/// Display + body typeface pairings.
enum FontPairing { clean, editorial, classic, modern, rounded, cadence, system }

enum ReplayGainMode { off, track, album }

enum DownloadEngineKind { auto, local, server }

enum AudioFormatChoice { original, m4a, opus, mp3, flac }

/// Typed wrapper around [SharedPreferences]. Everything the Settings screen edits
/// lives here; notifies listeners on every change so the UI and services stay in sync.
class SettingsStore extends ChangeNotifier {
  SettingsStore(this._prefs);

  final SharedPreferences _prefs;

  static Future<SettingsStore> load() async => SettingsStore(await SharedPreferences.getInstance());

  // --- generic helpers -----------------------------------------------------

  String? _s(String k) => _prefs.getString(k);
  bool _b(String k, bool d) => _prefs.getBool(k) ?? d;
  int _i(String k, int d) => _prefs.getInt(k) ?? d;
  double _d(String k, double d) => _prefs.getDouble(k) ?? d;

  Future<void> _set(String k, Object? v) async {
    if (v == null) {
      await _prefs.remove(k);
    } else if (v is String) {
      await _prefs.setString(k, v);
    } else if (v is bool) {
      await _prefs.setBool(k, v);
    } else if (v is int) {
      await _prefs.setInt(k, v);
    } else if (v is double) {
      await _prefs.setDouble(k, v);
    } else if (v is List<String>) {
      await _prefs.setStringList(k, v);
    }
    notifyListeners();
  }

  T _enum<T extends Enum>(String k, List<T> values, T d) {
    final name = _s(k);
    return values.firstWhere((e) => e.name == name, orElse: () => d);
  }

  /// Runtime value if set, otherwise the compile-time default.
  String _keyed(String k, String compileTime) {
    final v = _s(k);
    return (v == null || v.isEmpty) ? compileTime : v;
  }

  // --- downloads -----------------------------------------------------------

  /// Folder below Music/ where downloads are stored.
  String get downloadFolder => _s('dl.folder') ?? 'MusicPlayer';
  Future<void> setDownloadFolder(String v) => _set('dl.folder', v);

  AudioFormatChoice get downloadFormat =>
      _enum('dl.format', AudioFormatChoice.values, AudioFormatChoice.m4a);
  Future<void> setDownloadFormat(AudioFormatChoice v) => _set('dl.format', v.name);

  /// yt-dlp --audio-quality (0 best .. 10 worst) - only used when converting.
  int get downloadQuality => _i('dl.quality', 0);
  Future<void> setDownloadQuality(int v) => _set('dl.quality', v);

  String get filenameTemplate => _s('dl.template') ?? '{artist}/{album}/{track:02} - {title}';
  Future<void> setFilenameTemplate(String v) => _set('dl.template', v);

  bool get wifiOnly => _b('dl.wifiOnly', false);
  Future<void> setWifiOnly(bool v) => _set('dl.wifiOnly', v);

  int get maxConcurrent => _i('dl.concurrent', 2).clamp(1, 3);
  Future<void> setMaxConcurrent(int v) => _set('dl.concurrent', v);

  bool get sponsorBlock => _b('dl.sponsorblock', true);
  Future<void> setSponsorBlock(bool v) => _set('dl.sponsorblock', v);

  bool get autoIdentify => _b('dl.autoIdentify', true);
  Future<void> setAutoIdentify(bool v) => _set('dl.autoIdentify', v);

  bool get autoCover => _b('dl.autoCover', true);
  Future<void> setAutoCover(bool v) => _set('dl.autoCover', v);

  bool get autoLyrics => _b('dl.autoLyrics', true);
  Future<void> setAutoLyrics(bool v) => _set('dl.autoLyrics', v);

  bool get autoReplayGain => _b('dl.autoReplayGain', false);
  Future<void> setAutoReplayGain(bool v) => _set('dl.autoReplayGain', v);

  bool get embedLyrics => _b('dl.embedLyrics', false);
  Future<void> setEmbedLyrics(bool v) => _set('dl.embedLyrics', v);

  bool get writeLrcSidecar => _b('dl.writeLrc', false);
  Future<void> setWriteLrcSidecar(bool v) => _set('dl.writeLrc', v);

  bool get saveCoverJpg => _b('dl.saveCoverJpg', false);
  Future<void> setSaveCoverJpg(bool v) => _set('dl.saveCoverJpg', v);

  /// Rename/move downloaded files by [filenameTemplate] after identification.
  bool get organizeFiles => _b('dl.organize', true);
  Future<void> setOrganizeFiles(bool v) => _set('dl.organize', v);

  String? get cookiesFile => _s('dl.cookies');
  Future<void> setCookiesFile(String? v) => _set('dl.cookies', v);

  /// Extra yt-dlp flags, one per line, appended verbatim (power users).
  String get extraYtDlpArgs => _s('dl.extraArgs') ?? '';
  Future<void> setExtraYtDlpArgs(String v) => _set('dl.extraArgs', v);

  // --- downloader engine ---------------------------------------------------

  DownloadEngineKind get engineKind => _enum('eng.kind', DownloadEngineKind.values, DownloadEngineKind.auto);
  Future<void> setEngineKind(DownloadEngineKind v) => _set('eng.kind', v.name);

  String get serverUrl => _s('eng.serverUrl') ?? '';
  Future<void> setServerUrl(String v) => _set('eng.serverUrl', v.trim());

  String get serverToken => _s('eng.serverToken') ?? '';
  Future<void> setServerToken(String v) => _set('eng.serverToken', v.trim());

  /// "stable" | "nightly" | "master"
  String get ytDlpChannel => _s('eng.channel') ?? 'stable';
  Future<void> setYtDlpChannel(String v) => _set('eng.channel', v);

  bool get autoUpdateYtDlp => _b('eng.autoUpdate', true);
  Future<void> setAutoUpdateYtDlp(bool v) => _set('eng.autoUpdate', v);

  DateTime? get lastYtDlpUpdate {
    final ms = _prefs.getInt('eng.lastUpdate');
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<void> setLastYtDlpUpdate(DateTime v) => _set('eng.lastUpdate', v.millisecondsSinceEpoch);

  // --- library -------------------------------------------------------------

  int get minDurationSec => _i('lib.minDuration', 30);
  Future<void> setMinDurationSec(int v) => _set('lib.minDuration', v);

  List<String> get excludedFolders => _prefs.getStringList('lib.excluded') ?? const [];
  Future<void> setExcludedFolders(List<String> v) => _set('lib.excluded', v);

  bool get ignoreMessagingAudio => _b('lib.ignoreMessaging', true);
  Future<void> setIgnoreMessagingAudio(bool v) => _set('lib.ignoreMessaging', v);

  bool get libraryGrid => _b('lib.grid', true);
  Future<void> setLibraryGrid(bool v) => _set('lib.grid', v);

  // --- metadata ------------------------------------------------------------

  /// Ordered list of enabled metadata provider ids.
  List<String> get metadataProviders =>
      _prefs.getStringList('meta.providers') ?? const ['tags', 'acoustid', 'musicbrainz'];
  Future<void> setMetadataProviders(List<String> v) => _set('meta.providers', v);

  List<String> get coverProviders =>
      _prefs.getStringList('cover.providers') ?? const ['caa', 'caa-group', 'itunes', 'deezer', 'lastfm', 'embedded'];
  Future<void> setCoverProviders(List<String> v) => _set('cover.providers', v);

  List<String> get lyricsProviders =>
      _prefs.getStringList('lyrics.providers') ?? const ['embedded', 'lrclib'];
  Future<void> setLyricsProviders(List<String> v) => _set('lyrics.providers', v);

  double get autoAcceptThreshold => _d('meta.threshold', 0.9);
  Future<void> setAutoAcceptThreshold(double v) => _set('meta.threshold', v);

  /// ISO 3166 country used to prefer a regional release.
  String get preferredCountry => _s('meta.country') ?? 'US';
  Future<void> setPreferredCountry(String v) => _set('meta.country', v);

  bool get writeTagsToFiles => _b('meta.writeTags', true);
  Future<void> setWriteTagsToFiles(bool v) => _set('meta.writeTags', v);

  /// User-editable title clean-up regexes, one per line.
  String get titleRules => _s('meta.titleRules') ?? '';
  Future<void> setTitleRules(String v) => _set('meta.titleRules', v);

  // --- playback ------------------------------------------------------------

  bool get gapless => _b('play.gapless', true);
  Future<void> setGapless(bool v) => _set('play.gapless', v);

  /// 0 disables the fade. Applies a fade-out/fade-in around track changes.
  int get crossfadeSeconds => _i('play.crossfade', 0);
  Future<void> setCrossfadeSeconds(int v) => _set('play.crossfade', v);

  ReplayGainMode get replayGainMode => _enum('play.rg', ReplayGainMode.values, ReplayGainMode.track);
  Future<void> setReplayGainMode(ReplayGainMode v) => _set('play.rg', v.name);

  double get replayGainPreamp => _d('play.rgPreamp', 0);
  Future<void> setReplayGainPreamp(double v) => _set('play.rgPreamp', v);

  bool get resumeOnHeadphones => _b('play.resumeHeadphones', false);
  Future<void> setResumeOnHeadphones(bool v) => _set('play.resumeHeadphones', v);

  bool get pauseWhenNoisy => _b('play.noisy', true);
  Future<void> setPauseWhenNoisy(bool v) => _set('play.noisy', v);

  bool get duckForInterruptions => _b('play.duck', true);
  Future<void> setDuckForInterruptions(bool v) => _set('play.duck', v);

  bool get equalizerEnabled => _b('play.eqOn', false);
  Future<void> setEqualizerEnabled(bool v) => _set('play.eqOn', v);

  List<double> get equalizerGains {
    final raw = _s('play.eqGains');
    if (raw == null) return const [];
    return (jsonDecode(raw) as List).map((e) => (e as num).toDouble()).toList();
  }

  Future<void> setEqualizerGains(List<double> v) => _set('play.eqGains', jsonEncode(v));

  double get loudnessBoostDb => _d('play.boost', 0);
  Future<void> setLoudnessBoostDb(double v) => _set('play.boost', v);

  // --- restored playback state ------------------------------------------------

  int get queueIndex => _i('play.queueIndex', 0);
  int get queuePositionMs => _i('play.queuePos', 0);

  /// Saved without notifying: written every few seconds while playing.
  Future<void> saveQueuePosition(int index, int positionMs) async {
    await _prefs.setInt('play.queueIndex', index);
    await _prefs.setInt('play.queuePos', positionMs);
  }

  bool get shuffleOn => _b('play.shuffle', false);
  Future<void> setShuffleOn(bool v) => _set('play.shuffle', v);

  /// 0 = off, 1 = one, 2 = all
  int get repeatMode => _i('play.repeat', 0);
  Future<void> setRepeatMode(int v) => _set('play.repeat', v);

  // --- appearance ----------------------------------------------------------

  ThemePreference get themePreference => _enum('ui.theme', ThemePreference.values, ThemePreference.dark);
  Future<void> setThemePreference(ThemePreference v) async {
    // Moving off the legacy AMOLED choice keeps its black backgrounds as the pure-black switch.
    if (themePreference == ThemePreference.amoled && v != ThemePreference.amoled) await _prefs.setBool('ui.pureBlack', true);
    await _set('ui.theme', v.name);
  }

  /// Black backgrounds in dark mode (OLED).
  bool get pureBlack => _b('ui.pureBlack', false) || themePreference == ThemePreference.amoled;
  Future<void> setPureBlack(bool v) async {
    if (!v && themePreference == ThemePreference.amoled) await _prefs.setString('ui.theme', ThemePreference.dark.name);
    await _set('ui.pureBlack', v);
  }

  AppPalette get palette => _enum('ui.palette', AppPalette.values, AppPalette.green);
  Future<void> setPalette(AppPalette v) => _set('ui.palette', v.name);

  /// Hue (0-360) of the custom palette's accent.
  double get customHue => _d('ui.customHue', 160);
  Future<void> setCustomHue(double v) => _set('ui.customHue', v);

  /// How strongly the custom colour tints the background, 0 (neutral) to 1 (rich).
  double get customTint => _d('ui.customTint', 0.5);
  Future<void> setCustomTint(double v) => _set('ui.customTint', v);

  FontPairing get fontPairing => _enum('ui.fonts', FontPairing.values, FontPairing.clean);
  Future<void> setFontPairing(FontPairing v) => _set('ui.fonts', v.name);

  /// Last searches, newest first (at most 8, no duplicates).
  List<String> get recentSearches => _prefs.getStringList('search.recent') ?? const [];
  Future<void> addRecentSearch(String q) {
    final t = q.trim();
    if (t.isEmpty) return Future.value();
    // Typing "ab", "abb", "abba" keeps only "abba": earlier prefixes of the new query drop out.
    final lower = t.toLowerCase();
    final list = [t, ...recentSearches.where((e) => !lower.startsWith(e.toLowerCase()) && !e.toLowerCase().startsWith(lower))].take(8).toList();
    return _set('search.recent', list);
  }

  Future<void> clearRecentSearches() => _set('search.recent', null);

  /// Blurred cover art behind Now Playing.
  bool get ambientBackdrop => _b('ui.ambient', true);
  Future<void> setAmbientBackdrop(bool v) => _set('ui.ambient', v);

  bool get dynamicColor => _b('ui.dynamic', false);
  Future<void> setDynamicColor(bool v) => _set('ui.dynamic', v);

  bool get coverColors => _b('ui.coverColors', true);
  Future<void> setCoverColors(bool v) => _set('ui.coverColors', v);

  // --- sources -------------------------------------------------------------

  /// Source ids the user turned off (plan: sources are individually switchable).
  List<String> get disabledSources => _prefs.getStringList('src.disabled') ?? const [];
  Future<void> setDisabledSources(List<String> v) => _set('src.disabled', v);

  bool isSourceEnabled(String id) => !disabledSources.contains(id);

  // --- accounts & keys -----------------------------------------------------

  String get contact => _keyed('acc.contact', AppConfig.contact);
  Future<void> setContact(String v) => _set('acc.contact', v.trim());

  String get userAgent => '${AppConfig.appName.replaceAll(' ', '')}/${AppConfig.appVersion} ( $contact )';

  String get acoustIdKey => _keyed('key.acoustid', AppConfig.acoustIdKey);
  Future<void> setAcoustIdKey(String v) => _set('key.acoustid', v.trim());

  String get geniusToken => _keyed('key.genius', AppConfig.geniusToken);
  Future<void> setGeniusToken(String v) => _set('key.genius', v.trim());

  String get lastFmKey => _keyed('key.lastfm', AppConfig.lastFmKey);
  Future<void> setLastFmKey(String v) => _set('key.lastfm', v.trim());

  String get lastFmSecret => _keyed('key.lastfmSecret', AppConfig.lastFmSecret);
  Future<void> setLastFmSecret(String v) => _set('key.lastfmSecret', v.trim());

  String? get lastFmSession => _s('acc.lastfmSession');
  Future<void> setLastFmSession(String? v) => _set('acc.lastfmSession', v);

  String? get lastFmUser => _s('acc.lastfmUser');
  Future<void> setLastFmUser(String? v) => _set('acc.lastfmUser', v);

  String get listenBrainzToken => _keyed('key.lb', AppConfig.listenBrainzToken);
  Future<void> setListenBrainzToken(String v) => _set('key.lb', v.trim());

  String get discogsToken => _keyed('key.discogs', AppConfig.discogsToken);
  Future<void> setDiscogsToken(String v) => _set('key.discogs', v.trim());

  String get fanartKey => _keyed('key.fanart', AppConfig.fanartKey);
  Future<void> setFanartKey(String v) => _set('key.fanart', v.trim());

  String get audioDbKey => _keyed('key.audiodb', AppConfig.audioDbKey);
  Future<void> setAudioDbKey(String v) => _set('key.audiodb', v.trim());

  String get jamendoClientId => _keyed('key.jamendo', AppConfig.jamendoClientId);
  Future<void> setJamendoClientId(String v) => _set('key.jamendo', v.trim());

  String get podcastIndexKey => _keyed('key.pi', AppConfig.podcastIndexKey);
  Future<void> setPodcastIndexKey(String v) => _set('key.pi', v.trim());

  String get podcastIndexSecret => _keyed('key.piSecret', AppConfig.podcastIndexSecret);
  Future<void> setPodcastIndexSecret(String v) => _set('key.piSecret', v.trim());

  String get spotifyClientId => _keyed('key.spotifyId', AppConfig.spotifyClientId);
  Future<void> setSpotifyClientId(String v) => _set('key.spotifyId', v.trim());

  String get spotifyClientSecret => _keyed('key.spotifySecret', AppConfig.spotifyClientSecret);
  Future<void> setSpotifyClientSecret(String v) => _set('key.spotifySecret', v.trim());

  bool get scrobbleLastFm => _b('acc.scrobbleLastFm', true);
  Future<void> setScrobbleLastFm(bool v) => _set('acc.scrobbleLastFm', v);

  bool get scrobbleListenBrainz => _b('acc.scrobbleLb', true);
  Future<void> setScrobbleListenBrainz(bool v) => _set('acc.scrobbleLb', v);

  // --- misc state ----------------------------------------------------------

  bool get onboardingDone => _b('app.onboarded', false);
  Future<void> setOnboardingDone(bool v) => _set('app.onboarded', v);

  String get sleepTimerLast => _s('app.sleepLast') ?? '';
  Future<void> setSleepTimerLast(String v) => _set('app.sleepLast', v);

  /// Timestamps of periodic background jobs (yt-dlp update, release watcher...).
  DateTime? lastRun(String job) {
    final ms = _prefs.getInt('job.$job');
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<void> markRun(String job, [DateTime? at]) async {
    await _prefs.setInt('job.$job', (at ?? DateTime.now()).millisecondsSinceEpoch);
  }

  /// True when [job] has never run or last ran more than [every] ago.
  bool isDue(String job, Duration every, {DateTime? now}) {
    final last = lastRun(job);
    return last == null || (now ?? DateTime.now()).difference(last) >= every;
  }

  /// Export every stored preference (secrets included) for backup.
  Map<String, Object?> exportAll() => {for (final k in _prefs.getKeys()) k: _prefs.get(k)};

  Future<void> importAll(Map<String, dynamic> data) async {
    for (final e in data.entries) {
      final v = e.value;
      if (v is List) {
        await _prefs.setStringList(e.key, v.map((x) => x.toString()).toList());
      } else if (v is String || v is bool || v is int || v is double) {
        await _set(e.key, v);
      }
    }
    notifyListeners();
  }
}
