import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/app_services.dart';
import '../../core/settings/settings_store.dart';
import '../../app/brand.dart';
import '../../app/theme.dart';
import '../widgets/brand_logo.dart';
import '../widgets/common.dart';
import '../widgets/kit.dart';
import 'identify_screens.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget tile(IconData i, String t, String sub, Widget page, {bool accent = false}) => ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
          leading: Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(color: accent ? scheme.primaryContainer : scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(14)),
            child: Icon(i, size: 21, color: accent ? scheme.onPrimaryContainer : scheme.onSurface),
          ),
          title: Text(t),
          subtitle: Text(sub),
          trailing: Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page)),
        );
    return Scaffold(
      appBar: AppBar(toolbarHeight: screenTitleHeight, title: const ScreenTitle('Settings', eyebrow: Brand.name)),
      body: ListView(padding: EdgeInsets.only(bottom: bottomClearance(context)), children: [
        tile(Icons.palette_outlined, 'Appearance', 'Palette, typeface, theme, glass', const AppearanceScreen(), accent: true),
        _sectionTitle(context, 'Music'),
        tile(Icons.play_circle_outline_rounded, 'Playback', 'Gapless, fade, ReplayGain, headphones', const _PlaybackSettings()),
        tile(Icons.library_music_outlined, 'Library', 'Folders to scan, exclusions, minimum length', const _LibrarySettings()),
        tile(Icons.sell_outlined, 'Metadata', 'Providers, auto-accept threshold, tag writing', const _MetadataSettings()),
        tile(Icons.download_outlined, 'Downloads', 'Folder, format, engine, yt-dlp updates', const _DownloadSettings()),
        tile(Icons.travel_explore_rounded, 'Sources', 'Switch online sources on or off', const _SourceSettings()),
        _sectionTitle(context, 'You'),
        tile(Icons.key_rounded, 'Accounts & API keys', 'Last.fm, ListenBrainz, AcoustID, Genius…', const _AccountSettings()),
        tile(Icons.backup_outlined, 'Backup & restore', 'Playlists, play counts, ratings', const _BackupSettings()),
        tile(Icons.info_outline_rounded, 'About & legal', 'Licences, what you may download', const _AboutScreen()),
      ]),
    );
  }
}

Widget _sectionTitle(BuildContext context, String t) => Padding(padding: const EdgeInsets.fromLTRB(18, 26, 18, 6), child: Eyebrow(t, color: Theme.of(context).colorScheme.primary));

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

class AppearanceScreen extends StatelessWidget {
  const AppearanceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsStore>();
    final mode = s.themePreference == ThemePreference.amoled ? ThemePreference.dark : s.themePreference;
    return Scaffold(
      appBar: AppBar(toolbarHeight: screenTitleHeight, title: const ScreenTitle('Appearance', eyebrow: 'Make it yours')),
      body: ListView(padding: EdgeInsets.only(bottom: bottomClearance(context)), children: [
        _sectionTitle(context, 'Theme'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: SegmentedPills<ThemePreference>(
            options: const [ThemePreference.system, ThemePreference.light, ThemePreference.dark],
            selected: mode,
            label: (m) => switch (m) { ThemePreference.light => 'Light', ThemePreference.dark || ThemePreference.amoled => 'Dark', ThemePreference.system => 'System' },
            onSelect: s.setThemePreference,
          ),
        ),
        const SizedBox(height: 6),
        SwitchListTile(
          title: const Text('Pure black'),
          subtitle: const Text('Black backgrounds in dark mode, for OLED screens'),
          value: s.pureBlack,
          onChanged: mode == ThemePreference.light ? null : s.setPureBlack,
        ),
        _sectionTitle(context, 'Palette'),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
          child: Wrap(
            spacing: 4,
            runSpacing: 12,
            children: [
              for (final p in AppPalette.values)
                _PaletteSwatch(
                  spec: p == AppPalette.custom ? PaletteSpec.custom(s.customHue, s.customTint) : PaletteSpec.of(p),
                  rainbow: p == AppPalette.custom,
                  selected: !s.dynamicColor && s.palette == p,
                  onTap: () => _pickPalette(context, s, p),
                ),
            ],
          ),
        ),
        SwitchListTile(
          title: const Text('Wallpaper colours'),
          subtitle: const Text('Android 12+. Builds a palette from your wallpaper instead'),
          value: s.dynamicColor,
          onChanged: s.setDynamicColor,
        ),
        _sectionTitle(context, 'Typeface'),
        for (final f in FontPairing.values) _TypefaceTile(pairing: f, selected: s.fontPairing == f, onTap: () => s.setFontPairing(f)),
        _sectionTitle(context, 'Now Playing'),
        SwitchListTile(title: const Text('Colours from cover art'), subtitle: const Text('Each album tints the player in its own colours'), value: s.coverColors, onChanged: s.setCoverColors),
        SwitchListTile(title: const Text('Cover colour backdrop'), subtitle: const Text("Fill the player and its lyrics card with the cover's colour"), value: s.ambientBackdrop, onChanged: s.setAmbientBackdrop),
      ]),
    );
  }

  Future<void> _pickPalette(BuildContext context, SettingsStore s, AppPalette p) async {
    if (p == AppPalette.custom) return showCustomColorSheet(context);
    if (s.dynamicColor) await s.setDynamicColor(false);
    await s.setPalette(p);
  }
}

/// Opens the custom colour picker (and switches to the custom palette).
Future<void> showCustomColorSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const _CustomColorSheet(),
    );

/// Any colour you like: a rainbow hue slider, quick picks and how much it tints the background.
/// Changes preview live in the sheet and apply to the app when a slider is released.
class _CustomColorSheet extends StatefulWidget {
  const _CustomColorSheet();

  @override
  State<_CustomColorSheet> createState() => _CustomColorSheetState();
}

class _CustomColorSheetState extends State<_CustomColorSheet> {
  late final SettingsStore _s = context.read<SettingsStore>();
  late double _hue = _s.customHue;
  late double _tint = _s.customTint;

  static const _quick = <double>[0, 18, 36, 50, 95, 145, 172, 196, 218, 245, 270, 295, 325];

  Future<void> _apply() async {
    if (_s.dynamicColor) await _s.setDynamicColor(false);
    await _s.setCustomHue(_hue);
    await _s.setCustomTint(_tint);
    if (_s.palette != AppPalette.custom) await _s.setPalette(AppPalette.custom);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final preview = schemeFor(PaletteSpec.custom(_hue, _tint), t.brightness);
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 0, 22, 24),
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          const Eyebrow('Custom colour'),
          const SizedBox(height: 4),
          Text('Paint it your way', style: t.textTheme.headlineMedium),
          const SizedBox(height: 18),
          // Live preview: the page, an ink pill and an accent button in the new colours.
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: preview.surface, borderRadius: BorderRadius.circular(24), border: Border.all(color: preview.outlineVariant)),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('NOW PLAYING', style: t.textTheme.labelSmall?.copyWith(color: preview.primary, letterSpacing: 1.6)),
                  const SizedBox(height: 4),
                  Text('Your music', style: t.textTheme.headlineSmall?.copyWith(color: preview.onSurface)),
                  Text('in your colours', style: t.textTheme.bodySmall?.copyWith(color: preview.onSurfaceVariant)),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: ShapeDecoration(color: preview.inverseSurface, shape: const StadiumBorder()),
                    child: Text('Shuffle all', style: t.textTheme.labelLarge?.copyWith(color: preview.onInverseSurface)),
                  ),
                ]),
              ),
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(color: preview.primary, shape: BoxShape.circle),
                child: Icon(Icons.play_arrow_rounded, size: 34, color: preview.onPrimary),
              ),
            ]),
          ),
          const SizedBox(height: 22),
          Text('Colour', style: t.textTheme.titleSmall),
          const SizedBox(height: 10),
          _HueSlider(hue: _hue, onChanged: (v) => setState(() => _hue = v), onChangeEnd: (_) => _apply()),
          const SizedBox(height: 14),
          Wrap(spacing: 10, runSpacing: 10, children: [
            for (final h in _quick)
              Semantics(
                button: true,
                label: 'Hue ${h.round()}',
                child: GestureDetector(
                  onTap: () {
                    setState(() => _hue = h);
                    _apply();
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: schemeFor(PaletteSpec.custom(h, _tint), t.brightness).primary,
                      border: Border.all(color: (_hue - h).abs() < 1 ? t.colorScheme.onSurface : Colors.transparent, width: 2.5),
                    ),
                  ),
                ),
              ),
          ]),
          const SizedBox(height: 22),
          Row(children: [
            Expanded(child: Text('Background tint', style: t.textTheme.titleSmall)),
            Text(_tint < 0.2 ? 'Neutral' : (_tint < 0.65 ? 'Soft' : 'Rich'), style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ]),
          Slider(value: _tint, onChanged: (v) => setState(() => _tint = v), onChangeEnd: (_) => _apply()),
          const SizedBox(height: 8),
          PillButton(
            expand: true,
            height: 52,
            label: 'Done',
            onPressed: () async {
              await _apply();
              if (context.mounted) Navigator.pop(context);
            },
          ),
        ]),
      ),
    );
  }
}

/// A slider over a rainbow track.
class _HueSlider extends StatelessWidget {
  const _HueSlider({required this.hue, required this.onChanged, required this.onChangeEnd});

  final double hue;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: Stack(alignment: Alignment.center, children: [
        Container(
          height: 14,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(7),
            gradient: LinearGradient(colors: [for (var h = 0; h <= 360; h += 30) HSLColor.fromAHSL(1, (h % 360).toDouble(), 0.75, 0.55).toColor()]),
          ),
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 14,
            activeTrackColor: Colors.transparent,
            inactiveTrackColor: Colors.transparent,
            thumbColor: Colors.white,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 12, elevation: 3, pressedElevation: 5),
            trackShape: const RectangularSliderTrackShape(),
          ),
          child: Slider(min: 0, max: 360, value: hue.clamp(0, 360), onChanged: onChanged, onChangeEnd: onChangeEnd),
        ),
      ]),
    );
  }
}


/// A palette preview: its paper as a disc with the accent in the middle.
class _PaletteSwatch extends StatelessWidget {
  const _PaletteSwatch({required this.spec, required this.selected, required this.onTap, this.rainbow = false});

  final PaletteSpec spec;
  final bool selected;
  final VoidCallback onTap;

  /// The custom swatch wears a rainbow ring so it reads as "any colour".
  final bool rainbow;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final preview = schemeFor(spec, t.brightness);
    return Semantics(
      button: true,
      selected: selected,
      label: '${spec.label} palette',
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: SizedBox(
          width: 76,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 60,
                height: 60,
                padding: const EdgeInsets.all(3),
                decoration: rainbow && !selected
                    ? BoxDecoration(shape: BoxShape.circle, gradient: SweepGradient(colors: [for (var h = 0; h <= 360; h += 45) HSLColor.fromAHSL(1, (h % 360).toDouble(), 0.8, 0.6).toColor()]))
                    : BoxDecoration(shape: BoxShape.circle, border: Border.all(color: selected ? t.colorScheme.onSurface : Colors.transparent, width: 2)),
                child: Container(
                  decoration: BoxDecoration(shape: BoxShape.circle, color: preview.surface, border: Border.all(color: preview.outlineVariant)),
                  alignment: Alignment.center,
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: preview.primary),
                    child: selected ? Icon(Icons.check_rounded, size: 16, color: preview.onPrimary) : (rainbow ? Icon(Icons.colorize_rounded, size: 14, color: preview.onPrimary) : null),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(spec.label, style: t.textTheme.labelMedium?.copyWith(color: selected ? t.colorScheme.onSurface : t.colorScheme.onSurfaceVariant)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// A typeface pairing with a live "Aa" sample in its display face.
class _TypefaceTile extends StatelessWidget {
  const _TypefaceTile({required this.pairing, required this.selected, required this.onTap});

  final FontPairing pairing;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final spec = TypeSpec.of(pairing);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 2),
      selected: selected,
      onTap: onTap,
      leading: Container(
        width: 52,
        height: 52,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: selected ? t.colorScheme.inverseSurface : t.colorScheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(16)),
        child: Text('Aa', style: spec.displayStyle(30).copyWith(color: selected ? t.colorScheme.onInverseSurface : t.colorScheme.onSurface, height: 1.1)),
      ),
      title: Text(spec.label, style: TextStyle(fontFamily: spec.body, color: t.colorScheme.onSurface)),
      subtitle: Text(spec.description),
      trailing: AnimatedOpacity(
        opacity: selected ? 1 : 0,
        duration: const Duration(milliseconds: 160),
        child: Icon(Icons.check_rounded, color: t.colorScheme.primary),
      ),
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
