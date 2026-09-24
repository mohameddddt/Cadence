import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/app_services.dart';
import '../../core/settings/settings_store.dart';
import '../../app/brand.dart';
import '../widgets/brand_logo.dart';
import '../widgets/common.dart';
import 'identify_screens.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    Widget tile(IconData i, String t, String sub, Widget page) => ListTile(
          leading: Icon(i),
          title: Text(t),
          subtitle: Text(sub),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page)),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(children: [
        tile(Icons.download, 'Downloads', 'Folder, format, engine, yt-dlp updates', const _DownloadSettings()),
        tile(Icons.library_music, 'Library', 'Folders to scan, exclusions, minimum length', const _LibrarySettings()),
        tile(Icons.sell_outlined, 'Metadata', 'Providers, auto-accept threshold, tag writing', const _MetadataSettings()),
        tile(Icons.play_circle_outline, 'Playback', 'Gapless, fade, ReplayGain, headphones', const _PlaybackSettings()),
        tile(Icons.travel_explore, 'Sources', 'Switch online sources on or off', const _SourceSettings()),
        tile(Icons.key, 'Accounts & API keys', 'Last.fm, ListenBrainz, AcoustID, Genius…', const _AccountSettings()),
        tile(Icons.palette_outlined, 'Appearance', 'Theme, wallpaper colours', const _AppearanceSettings()),
        tile(Icons.backup_outlined, 'Backup & restore', 'Playlists, play counts, ratings', const _BackupSettings()),
        tile(Icons.info_outline, 'About & legal', 'Licences, what you may download', const _AboutScreen()),
      ]),
    );
  }
}

Widget _sectionTitle(BuildContext context, String t) => Padding(padding: const EdgeInsets.fromLTRB(16, 20, 16, 4), child: Text(t, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.primary)));

Future<void> _editText(BuildContext context, {required String title, required String initial, required Future<void> Function(String) onSave, bool obscure = false, int lines = 1, String? hint}) async {
  final c = TextEditingController(text: initial);
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(title),
      content: TextField(controller: c, autofocus: true, obscureText: obscure, minLines: lines, maxLines: lines == 1 ? 1 : lines + 3, decoration: InputDecoration(hintText: hint, border: const OutlineInputBorder())),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Save'))],
    ),
  );
  if (ok == true) await onSave(c.text);
}

Widget _textSetting(BuildContext context, {required String title, required String value, required Future<void> Function(String) onSave, bool secret = false, String? hint, int lines = 1}) => ListTile(
      title: Text(title),
      subtitle: Text(value.isEmpty ? (hint ?? 'Not set') : (secret ? '••••••••' : value), maxLines: 2, overflow: TextOverflow.ellipsis),
      onTap: () => _editText(context, title: title, initial: value, onSave: onSave, obscure: false, lines: lines, hint: hint),
    );

// ---------------------------------------------------------------------------

class _DownloadSettings extends StatelessWidget {
  const _DownloadSettings();

  @override
  Widget build(BuildContext context) {
    final services = context.read<AppServices>();
    final s = context.watch<SettingsStore>();
    return Scaffold(
      appBar: AppBar(title: const Text('Downloads')),
      body: ListView(children: [
        _sectionTitle(context, 'Files'),
        _textSetting(context, title: 'Folder (inside Music/)', value: s.downloadFolder, onSave: (v) => s.setDownloadFolder(v.trim().isEmpty ? 'MusicPlayer' : v.trim())),
        ListTile(
          title: const Text('Format'),
          subtitle: Text(switch (s.downloadFormat) {
            AudioFormatChoice.original => 'Original (no quality loss)',
            AudioFormatChoice.m4a => 'M4A (AAC)',
            AudioFormatChoice.opus => 'Opus',
            AudioFormatChoice.mp3 => 'MP3',
            AudioFormatChoice.flac => 'FLAC (lossless container, not better quality)',
          }),
          trailing: DropdownButton<AudioFormatChoice>(value: s.downloadFormat, underline: const SizedBox.shrink(), items: [for (final f in AudioFormatChoice.values) DropdownMenuItem(value: f, child: Text(f.name))], onChanged: (v) => s.setDownloadFormat(v!)),
        ),
        const ListTile(dense: true, title: Text('YouTube tops out at ~160 kbps Opus / 128 kbps AAC. Converting to MP3 320 does not add quality, only size. "Original" or M4A is recommended. Opus files cannot be tagged in place (tags stay in the app).')),
        _textSetting(context, title: 'Filename template', value: s.filenameTemplate, hint: '{artist}/{album}/{track:02} - {title}', onSave: s.setFilenameTemplate),
        SwitchListTile(title: const Text('Organise files after identification'), subtitle: const Text('Move into Artist/Album folders once tags are known'), value: s.organizeFiles, onChanged: s.setOrganizeFiles),
        _sectionTitle(context, 'Automation'),
        SwitchListTile(title: const Text('Auto-identify (AcoustID + MusicBrainz)'), value: s.autoIdentify, onChanged: s.setAutoIdentify),
        SwitchListTile(title: const Text('Fetch album cover'), value: s.autoCover, onChanged: s.setAutoCover),
        SwitchListTile(title: const Text('Fetch lyrics'), value: s.autoLyrics, onChanged: s.setAutoLyrics),
        SwitchListTile(title: const Text('Measure ReplayGain'), subtitle: const Text('Slower, but evens out loudness'), value: s.autoReplayGain, onChanged: s.setAutoReplayGain),
        SwitchListTile(title: const Text('Remove non-music parts (SponsorBlock)'), subtitle: const Text('YouTube music videos: intros, outros, talking'), value: s.sponsorBlock, onChanged: s.setSponsorBlock),
        SwitchListTile(title: const Text('Embed lyrics in files'), value: s.embedLyrics, onChanged: s.setEmbedLyrics),
        SwitchListTile(title: const Text('Write .lrc next to songs'), subtitle: const Text('Needs storage access; best effort'), value: s.writeLrcSidecar, onChanged: s.setWriteLrcSidecar),
        SwitchListTile(title: const Text('Save cover.jpg in album folder'), subtitle: const Text('Needs storage access; best effort'), value: s.saveCoverJpg, onChanged: s.setSaveCoverJpg),
        _sectionTitle(context, 'Network'),
        SwitchListTile(title: const Text('Download on Wi-Fi only'), value: s.wifiOnly, onChanged: s.setWifiOnly),
        ListTile(
          title: const Text('Simultaneous downloads'),
          subtitle: Slider(min: 1, max: 3, divisions: 2, label: '${s.maxConcurrent}', value: s.maxConcurrent.toDouble(), onChanged: (v) => s.setMaxConcurrent(v.round())),
          trailing: Text('${s.maxConcurrent}'),
        ),
        _sectionTitle(context, 'Downloader engine'),
        ListTile(
          title: const Text('Engine'),
          subtitle: const Text('Auto = on-device yt-dlp on Android, companion server otherwise'),
          trailing: DropdownButton<DownloadEngineKind>(value: s.engineKind, underline: const SizedBox.shrink(), items: [for (final e in DownloadEngineKind.values) DropdownMenuItem(value: e, child: Text(e.name))], onChanged: (v) => s.setEngineKind(v!)),
        ),
        _textSetting(context, title: 'Server URL', value: s.serverUrl, hint: 'http://100.x.y.z:8000 (Tailscale)', onSave: s.setServerUrl),
        _textSetting(context, title: 'Server token', value: s.serverToken, secret: true, onSave: s.setServerToken),
        ListTile(
          title: const Text('Test server connection'),
          trailing: const Icon(Icons.network_check),
          onTap: () async {
            try {
              final v = await services.engines.server.version();
              if (context.mounted) showSnack(context, 'Server reachable. yt-dlp $v');
            } on Object catch (e) {
              if (context.mounted) showSnack(context, 'Server error: $e');
            }
          },
        ),
        ListTile(
          title: const Text('yt-dlp release channel'),
          trailing: DropdownButton<String>(value: s.ytDlpChannel, underline: const SizedBox.shrink(), items: const [DropdownMenuItem(value: 'stable', child: Text('stable')), DropdownMenuItem(value: 'nightly', child: Text('nightly')), DropdownMenuItem(value: 'master', child: Text('master'))], onChanged: (v) => s.setYtDlpChannel(v!)),
        ),
        SwitchListTile(title: const Text('Update yt-dlp weekly'), subtitle: Text(s.lastYtDlpUpdate == null ? 'Never updated' : 'Last updated ${s.lastYtDlpUpdate}'), value: s.autoUpdateYtDlp, onChanged: s.setAutoUpdateYtDlp),
        ListTile(
          title: const Text('Update yt-dlp now'),
          subtitle: const Text('YouTube changes often - update when downloads fail'),
          trailing: const Icon(Icons.system_update_alt),
          onTap: () async {
            showSnack(context, 'Updating…');
            try {
              final r = await services.engines.current.update(s.ytDlpChannel);
              await s.setLastYtDlpUpdate(DateTime.now());
              if (context.mounted) showSnack(context, 'Done: $r');
            } on Object catch (e) {
              if (context.mounted) showSnack(context, 'Update failed: $e');
            }
          },
        ),
        _sectionTitle(context, 'Advanced'),
        ListTile(
          title: const Text('Cookies file'),
          subtitle: Text(s.cookiesFile ?? 'For age-restricted or members-only content, from your own account'),
          trailing: s.cookiesFile == null ? const Icon(Icons.attach_file) : IconButton(icon: const Icon(Icons.close), onPressed: () => s.setCookiesFile(null)),
          onTap: () async {
            final f = await FilePicker.pickFile();
            if (f?.path != null) {
              // copy into app storage so it stays readable
              final dest = File('${services.supportDir.path}/cookies.txt');
              await File(f!.path!).copy(dest.path);
              await s.setCookiesFile(dest.path);
            }
          },
        ),
        _textSetting(context, title: 'Extra yt-dlp arguments', value: s.extraYtDlpArgs, hint: 'one per line, e.g. --geo-bypass', lines: 3, onSave: s.setExtraYtDlpArgs),
        ListTile(
          title: const Text('Battery optimisation'),
          subtitle: const Text('Exempt the app so long downloads are not killed'),
          trailing: const Icon(Icons.battery_saver),
          onTap: () async {
            final sys = services.bridges.system;
            if (await sys.isIgnoringBatteryOptimizations()) {
              if (context.mounted) showSnack(context, 'Already exempt');
            } else {
              await sys.requestIgnoreBatteryOptimizations();
            }
          },
        ),
      ]),
    );
  }
}

class _LibrarySettings extends StatelessWidget {
  const _LibrarySettings();

  @override
  Widget build(BuildContext context) {
    final services = context.read<AppServices>();
    final s = context.watch<SettingsStore>();
    return Scaffold(
      appBar: AppBar(title: const Text('Library')),
      body: ListView(children: [
        _sectionTitle(context, 'Folders'),
        FutureBuilder(
          future: services.bridges.mediaStore.persistedFolders(),
          builder: (context, snap) => Column(children: [
            const ListTile(title: Text('Everything MediaStore knows about is included automatically.'), dense: true),
            for (final f in snap.data ?? const []) ListTile(leading: const Icon(Icons.folder), title: Text(f.name), subtitle: Text(f.uri, maxLines: 1, overflow: TextOverflow.ellipsis), trailing: IconButton(icon: const Icon(Icons.close), onPressed: () async {
                  await services.bridges.mediaStore.releaseFolder(f.uri);
                  await services.scanner.scan();
                  if (context.mounted) (context as Element).markNeedsBuild();
                })),
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('Add a folder'),
              subtitle: const Text('SD card or any folder the system scanner misses'),
              onTap: () async {
                final f = await services.bridges.mediaStore.pickFolder();
                if (f != null) await services.scanner.scan(force: true);
                if (context.mounted) (context as Element).markNeedsBuild();
              },
            ),
          ]),
        ),
        _sectionTitle(context, 'Filters'),
        _textSetting(context, title: 'Excluded folders (one path per line)', value: s.excludedFolders.join('\n'), lines: 3, hint: '/storage/emulated/0/Ringtones', onSave: (v) => s.setExcludedFolders(v.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList())),
        ListTile(
          title: const Text('Ignore clips shorter than'),
          subtitle: Slider(min: 0, max: 120, divisions: 24, value: s.minDurationSec.toDouble(), label: '${s.minDurationSec}s', onChanged: (v) => s.setMinDurationSec(v.round())),
          trailing: Text('${s.minDurationSec}s'),
        ),
        SwitchListTile(title: const Text('Ignore WhatsApp / Telegram / voice notes'), value: s.ignoreMessagingAudio, onChanged: s.setIgnoreMessagingAudio),
        ListTile(
          leading: const Icon(Icons.refresh),
          title: const Text('Rescan now'),
          subtitle: const Text('Full rescan re-reads every file'),
          onTap: () async {
            showSnack(context, 'Scanning…');
            final r = await services.scanner.scan(force: true);
            if (context.mounted) showSnack(context, '${r.total} songs (${r.added} new, ${r.removed} removed)');
          },
        ),
        ListTile(
          leading: const Icon(Icons.graphic_eq),
          title: const Text('Measure ReplayGain for all songs'),
          subtitle: const Text('Runs in the foreground; can take a while'),
          onTap: () async {
            final stream = services.loudness.analyzeMissing();
            await for (final p in stream) {
              if (!context.mounted) return;
              showSnack(context, 'Analysing ${p.done}/${p.total}', duration: const Duration(seconds: 1));
            }
          },
        ),
        ListTile(leading: const Icon(Icons.auto_fix_high), title: const Text('Fix tags…'), onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const FixTagsScreen()))),
      ]),
    );
  }
}

class _MetadataSettings extends StatelessWidget {
  const _MetadataSettings();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsStore>();
    Widget providerSwitch(String id, String label, List<String> current, Future<void> Function(List<String>) save) => SwitchListTile(
          title: Text(label),
          value: current.contains(id),
          onChanged: (v) => save(v ? [...current, id] : current.where((e) => e != id).toList()),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('Metadata')),
      body: ListView(children: [
        _sectionTitle(context, 'Identification providers'),
        providerSwitch('tags', 'Trust MusicBrainz ids already in tags', s.metadataProviders, s.setMetadataProviders),
        providerSwitch('acoustid', 'Acoustic fingerprint (AcoustID)', s.metadataProviders, s.setMetadataProviders),
        providerSwitch('musicbrainz', 'Title search (MusicBrainz)', s.metadataProviders, s.setMetadataProviders),
        ListTile(
          title: const Text('Auto-accept threshold'),
          subtitle: Slider(min: 0.6, max: 1.0, divisions: 8, value: s.autoAcceptThreshold, label: '${(s.autoAcceptThreshold * 100).round()}%', onChanged: s.setAutoAcceptThreshold),
          trailing: Text('${(s.autoAcceptThreshold * 100).round()}%'),
        ),
        _textSetting(context, title: 'Preferred release country', value: s.preferredCountry, hint: 'US, GB, DE…', onSave: (v) => s.setPreferredCountry(v.trim().toUpperCase())),
        SwitchListTile(title: const Text('Write tags into files'), subtitle: const Text('Otherwise metadata stays inside the app only'), value: s.writeTagsToFiles, onChanged: s.setWriteTagsToFiles),
        _textSetting(context, title: 'Title clean-up rules (regex, one per line)', value: s.titleRules, lines: 3, hint: r'e.g.  \bNCS Release\b', onSave: s.setTitleRules),
        _sectionTitle(context, 'Cover art providers'),
        for (final p in const [('caa', 'Cover Art Archive (release)'), ('caa-group', 'Cover Art Archive (release group)'), ('itunes', 'iTunes'), ('deezer', 'Deezer'), ('lastfm', 'Last.fm')]) providerSwitch(p.$1, p.$2, s.coverProviders, s.setCoverProviders),
        _sectionTitle(context, 'Lyrics providers'),
        providerSwitch('embedded', 'Embedded tags / .lrc files', s.lyricsProviders, s.setLyricsProviders),
        providerSwitch('lrclib', 'LRCLIB (synced lyrics)', s.lyricsProviders, s.setLyricsProviders),
      ]),
    );
  }
}

class _PlaybackSettings extends StatelessWidget {
  const _PlaybackSettings();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsStore>();
    return Scaffold(
      appBar: AppBar(title: const Text('Playback')),
      body: ListView(children: [
        SwitchListTile(title: const Text('Gapless playback'), subtitle: const Text('Always on for files with correct encoder padding'), value: s.gapless, onChanged: s.setGapless),
        ListTile(
          title: const Text('Fade between songs'),
          subtitle: Slider(min: 0, max: 12, divisions: 12, value: s.crossfadeSeconds.toDouble(), label: s.crossfadeSeconds == 0 ? 'off' : '${s.crossfadeSeconds}s', onChanged: (v) => s.setCrossfadeSeconds(v.round())),
          trailing: Text(s.crossfadeSeconds == 0 ? 'Off' : '${s.crossfadeSeconds}s'),
        ),
        ListTile(
          title: const Text('ReplayGain'),
          trailing: DropdownButton<ReplayGainMode>(value: s.replayGainMode, underline: const SizedBox.shrink(), items: [for (final m in ReplayGainMode.values) DropdownMenuItem(value: m, child: Text(m.name))], onChanged: (v) => s.setReplayGainMode(v!)),
        ),
        ListTile(
          title: const Text('ReplayGain pre-amp'),
          subtitle: Slider(min: -6, max: 6, divisions: 12, value: s.replayGainPreamp, label: '${s.replayGainPreamp.round()} dB', onChanged: (v) => s.setReplayGainPreamp(v.roundToDouble())),
          trailing: Text('${s.replayGainPreamp.round()} dB'),
        ),
        SwitchListTile(title: const Text('Pause when headphones unplug'), value: s.pauseWhenNoisy, onChanged: s.setPauseWhenNoisy),
        SwitchListTile(title: const Text('Resume when headphones reconnect'), value: s.resumeOnHeadphones, onChanged: s.setResumeOnHeadphones),
        SwitchListTile(title: const Text('Lower volume for navigation prompts'), subtitle: const Text('Off = pause instead'), value: s.duckForInterruptions, onChanged: s.setDuckForInterruptions),
      ]),
    );
  }
}

class _SourceSettings extends StatelessWidget {
  const _SourceSettings();

  @override
  Widget build(BuildContext context) {
    final services = context.read<AppServices>();
    final s = context.watch<SettingsStore>();
    return Scaffold(
      appBar: AppBar(title: const Text('Sources')),
      body: ListView(children: [
        const ListTile(dense: true, title: Text('Turn sources off to hide them from search and links. Each source has its own rules - respect them.')),
        for (final p in services.sources.providers)
          SwitchListTile(
            title: Text(p.label),
            subtitle: p.note == null ? null : Text(p.note!),
            value: s.isSourceEnabled(p.id),
            onChanged: (v) => s.setDisabledSources(v ? s.disabledSources.where((e) => e != p.id).toList() : [...s.disabledSources, p.id]),
          ),
      ]),
    );
  }
}

class _AccountSettings extends StatelessWidget {
  const _AccountSettings();

  @override
  Widget build(BuildContext context) {
    final services = context.read<AppServices>();
    final s = context.watch<SettingsStore>();
    return Scaffold(
      appBar: AppBar(title: const Text('Accounts & API keys')),
      body: ListView(children: [
        const ListTile(dense: true, title: Text('All keys are free. They are stored only on this device (never commit them).')),
        _sectionTitle(context, 'MusicBrainz etiquette'),
        _textSetting(context, title: 'Contact for User-Agent', value: s.contact, hint: 'you@example.com or a URL', onSave: s.setContact),
        _sectionTitle(context, 'Identification & lyrics'),
        _textSetting(context, title: 'AcoustID application key', value: s.acoustIdKey, secret: true, hint: 'acoustid.org/new-application', onSave: s.setAcoustIdKey),
        _textSetting(context, title: 'Genius client access token', value: s.geniusToken, secret: true, hint: 'genius.com/api-clients (song info + link only)', onSave: s.setGeniusToken),
        _sectionTitle(context, 'Last.fm'),
        _textSetting(context, title: 'API key', value: s.lastFmKey, secret: true, hint: 'last.fm/api/account/create', onSave: s.setLastFmKey),
        _textSetting(context, title: 'Shared secret', value: s.lastFmSecret, secret: true, onSave: s.setLastFmSecret),
        ListTile(
          title: Text(s.lastFmSession == null ? 'Sign in to scrobble' : 'Signed in as ${s.lastFmUser}'),
          trailing: s.lastFmSession == null ? const Icon(Icons.login) : TextButton(onPressed: () async {
                await s.setLastFmSession(null);
                await s.setLastFmUser(null);
              }, child: const Text('Sign out')),
          onTap: s.lastFmSession != null ? null : () => _lastFmLogin(context, services),
        ),
        SwitchListTile(title: const Text('Scrobble to Last.fm'), value: s.scrobbleLastFm, onChanged: s.setScrobbleLastFm),
        _sectionTitle(context, 'ListenBrainz'),
        _textSetting(context, title: 'User token', value: s.listenBrainzToken, secret: true, hint: 'listenbrainz.org/settings', onSave: s.setListenBrainzToken),
        ListTile(
          title: const Text('Check token'),
          onTap: () async {
            final u = await services.listenBrainz.validate();
            if (context.mounted) showSnack(context, u == null ? 'Token not valid' : 'Valid token for $u');
          },
        ),
        SwitchListTile(title: const Text('Scrobble to ListenBrainz'), value: s.scrobbleListenBrainz, onChanged: s.setScrobbleListenBrainz),
        FutureBuilder<int>(
          future: services.scrobble.pendingCount(),
          builder: (context, snap) => ListTile(
            title: Text('${snap.data ?? 0} listens waiting to be sent'),
            trailing: TextButton(onPressed: () async {
              final r = await services.scrobble.flush();
              if (context.mounted) showSnack(context, r.errors.isEmpty ? 'Sent ${r.lastFm + r.listenBrainz}' : r.errors.first);
            }, child: const Text('Send now')),
          ),
        ),
        _sectionTitle(context, 'Artist info & artwork'),
        _textSetting(context, title: 'fanart.tv key', value: s.fanartKey, secret: true, onSave: s.setFanartKey),
        _textSetting(context, title: 'TheAudioDB key', value: s.audioDbKey, secret: true, hint: 'default: 2 (test key)', onSave: s.setAudioDbKey),
        _textSetting(context, title: 'Discogs token', value: s.discogsToken, secret: true, onSave: s.setDiscogsToken),
        _sectionTitle(context, 'Sources'),
        _textSetting(context, title: 'Jamendo client id', value: s.jamendoClientId, secret: true, onSave: s.setJamendoClientId),
        _textSetting(context, title: 'Podcast Index key', value: s.podcastIndexKey, secret: true, onSave: s.setPodcastIndexKey),
        _textSetting(context, title: 'Podcast Index secret', value: s.podcastIndexSecret, secret: true, onSave: s.setPodcastIndexSecret),
        _textSetting(context, title: 'Spotify client id', value: s.spotifyClientId, secret: true, hint: 'for playlist import (public playlists)', onSave: s.setSpotifyClientId),
        _textSetting(context, title: 'Spotify client secret', value: s.spotifyClientSecret, secret: true, onSave: s.setSpotifyClientSecret),
      ]),
    );
  }

  Future<void> _lastFmLogin(BuildContext context, AppServices services) async {
    final user = TextEditingController(), pass = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Last.fm sign-in'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: user, decoration: const InputDecoration(labelText: 'Username')),
          TextField(controller: pass, obscureText: true, decoration: const InputDecoration(labelText: 'Password')),
          const SizedBox(height: 8),
          const Text('The password is only used to obtain a session key and is not stored.', style: TextStyle(fontSize: 12)),
        ]),
        actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Sign in'))],
      ),
    );
    if (ok != true) return;
    try {
      final r = await services.lastFm.login(user.text.trim(), pass.text);
      await services.settings.setLastFmSession(r.key);
      await services.settings.setLastFmUser(r.name);
      if (context.mounted) showSnack(context, 'Signed in as ${r.name}');
    } on Object catch (e) {
      if (context.mounted) showSnack(context, 'Sign-in failed: $e');
    }
  }
}

class _AppearanceSettings extends StatelessWidget {
  const _AppearanceSettings();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsStore>();
    return Scaffold(
      appBar: AppBar(title: const Text('Appearance')),
      body: ListView(children: [
        RadioGroup<ThemePreference>(
          groupValue: s.themePreference,
          onChanged: (v) => s.setThemePreference(v!),
          child: Column(children: [
            for (final t in ThemePreference.values)
              RadioListTile<ThemePreference>(
                title: Text(switch (t) { ThemePreference.system => 'System', ThemePreference.light => 'Light', ThemePreference.dark => 'Dark', ThemePreference.amoled => 'AMOLED black' }),
                value: t,
              ),
          ]),
        ),
        const Divider(),
        SwitchListTile(title: const Text('Wallpaper colours (Material You)'), subtitle: const Text('Android 12+. Off keeps the Cadence palette'), value: s.dynamicColor, onChanged: s.setDynamicColor),
        SwitchListTile(title: const Text('Colours from cover art on Now Playing'), value: s.coverColors, onChanged: s.setCoverColors),
      ]),
    );
  }
}

class _BackupSettings extends StatelessWidget {
  const _BackupSettings();

  @override
  Widget build(BuildContext context) {
    final services = context.read<AppServices>();
    return Scaffold(
      appBar: AppBar(title: const Text('Backup & restore')),
      body: ListView(children: [
        const ListTile(dense: true, title: Text('Exports playlists, play counts, ratings, favourites, lyrics offsets, wishlist, podcasts and radio favourites as JSON. Songs are matched again by path, MusicBrainz id or title + artist when restoring.')),
        ListTile(
          leading: const Icon(Icons.upload_file),
          title: const Text('Export backup'),
          onTap: () async {
            final data = await services.repo.exportUserData();
            final bytes = Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent(' ').convert(data)));
            final uri = await FilePicker.saveFile(fileName: 'musicplayer-backup-${DateTime.now().toIso8601String().substring(0, 10)}.json', bytes: bytes, mimeType: 'application/json');
            if (context.mounted && uri != null) showSnack(context, 'Backup saved');
          },
        ),
        ListTile(
          leading: const Icon(Icons.download_for_offline),
          title: const Text('Restore backup'),
          onTap: () async {
            final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['json']);
            if (f?.path == null) return;
            try {
              final data = jsonDecode(await File(f!.path!).readAsString()) as Map<String, dynamic>;
              final n = await services.repo.importUserData(data);
              if (context.mounted) showSnack(context, 'Restored - $n songs matched');
            } on Object catch (e) {
              if (context.mounted) showSnack(context, 'Not a valid backup: $e');
            }
          },
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.key),
          title: const Text('Export settings & API keys'),
          subtitle: const Text('Contains your secret keys - keep the file private'),
          onTap: () async {
            final bytes = Uint8List.fromList(utf8.encode(jsonEncode(services.settings.exportAll())));
            await FilePicker.saveFile(fileName: 'musicplayer-settings.json', bytes: bytes, mimeType: 'application/json');
          },
        ),
        ListTile(
          leading: const Icon(Icons.settings_backup_restore),
          title: const Text('Import settings'),
          onTap: () async {
            final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['json']);
            if (f?.path == null) return;
            await services.settings.importAll(jsonDecode(await File(f!.path!).readAsString()) as Map<String, dynamic>);
            if (context.mounted) showSnack(context, 'Settings imported');
          },
        ),
      ]),
    );
  }
}

class _AboutScreen extends StatelessWidget {
  const _AboutScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('About & legal')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Align(alignment: Alignment.centerLeft, child: BrandTile(size: 72)),
        const SizedBox(height: 16),
        Text('${Brand.name} ${AppVersion.value}', style: Theme.of(context).textTheme.titleLarge),
        Text(Brand.tagline, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.primary)),
        const SizedBox(height: 12),
        const Text('A personal, open-source (GPL-3.0) player for your local files, with downloading, tagging, covers and lyrics.'),
        const SizedBox(height: 16),
        Text('Read this before downloading', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        for (final t in const [
          'YouTube: downloading breaks YouTube\'s terms of service. Use it only for content you own or that is freely licensed. This is why the app is distributed outside Google Play.',
          'Bandcamp: download free / name-your-price releases or things you bought; the stream is 128 kbps.',
          'SoundCloud: many tracks are stream-only - respect the artist\'s settings. Go+ tracks are DRM protected and will not work.',
          'Internet Archive, Audius, Jamendo, ccMixter: mostly public domain or Creative Commons - the safest sources.',
          'Genius: only song info and a link are used; lyrics text comes from LRCLIB (open database).',
          'MusicBrainz: the app identifies itself and stays under 1 request per second.',
        ])
          Padding(padding: const EdgeInsets.only(bottom: 8), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('•  '), Expanded(child: Text(t))])),
        const SizedBox(height: 8),
        OutlinedButton(onPressed: () => showLicensePage(context: context, applicationName: Brand.name), child: const Text('Open-source licences')),
      ]),
    );
  }
}

/// Version string shown in About (kept in sync with pubspec by the release script).
class AppVersion {
  const AppVersion._();
  static const String value = '0.1.0';
}
