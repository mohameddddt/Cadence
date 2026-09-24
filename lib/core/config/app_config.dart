/// Compile-time defaults. Every value can be overridden at runtime in
/// Settings (see [SettingsStore]); keys are never committed to the repo.
///
/// Build with:  flutter run --dart-define-from-file=env.json
/// (copy env.example.json to env.json - it is git-ignored).
class AppConfig {
  const AppConfig._();

  static const String appName = 'Cadence';
  static const String appVersion = '0.1.0';

  static const String acoustIdKey = String.fromEnvironment('ACOUSTID_KEY');
  static const String geniusToken = String.fromEnvironment('GENIUS_TOKEN');
  static const String lastFmKey = String.fromEnvironment('LASTFM_KEY');
  static const String lastFmSecret = String.fromEnvironment('LASTFM_SECRET');
  static const String listenBrainzToken = String.fromEnvironment('LISTENBRAINZ_TOKEN');
  static const String discogsToken = String.fromEnvironment('DISCOGS_TOKEN');
  static const String fanartKey = String.fromEnvironment('FANART_KEY');
  static const String audioDbKey = String.fromEnvironment('AUDIODB_KEY', defaultValue: '2');
  static const String jamendoClientId = String.fromEnvironment('JAMENDO_CLIENT_ID');
  static const String podcastIndexKey = String.fromEnvironment('PODCASTINDEX_KEY');
  static const String podcastIndexSecret = String.fromEnvironment('PODCASTINDEX_SECRET');
  static const String spotifyClientId = String.fromEnvironment('SPOTIFY_CLIENT_ID');
  static const String spotifyClientSecret = String.fromEnvironment('SPOTIFY_CLIENT_SECRET');

  /// Contact details for the MusicBrainz-mandated User-Agent
  /// ("Application/version ( contact )"). Set your own in Settings > Accounts.
  static const String contact = String.fromEnvironment(
    'CONTACT',
    defaultValue: 'https://github.com/personal/musicplayer',
  );
}
