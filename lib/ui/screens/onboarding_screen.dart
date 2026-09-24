import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../../app/app_services.dart';
import '../../app/brand.dart';
import '../widgets/brand_logo.dart';
import '../widgets/common.dart';

/// First launch: explain what the app needs (audio access, notifications), let the user add
/// folders and set up downloads, then start scanning.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.onDone});
  final VoidCallback onDone;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  bool _audio = false;
  bool _notif = false;
  int _folders = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  static Future<Permission> audioPermission(AppServices s) async => await s.bridges.system.sdkInt() >= 33 ? Permission.audio : Permission.storage;

  Future<void> _refresh() async {
    final s = context.read<AppServices>();
    final a = await (await audioPermission(s)).status;
    final n = await Permission.notification.status;
    var f = 0;
    try {
      f = (await s.bridges.mediaStore.persistedFolders()).length;
    } on Object {
      // not on Android
    }
    if (mounted) {
      setState(() {
        _audio = a.isGranted || a.isLimited;
        _notif = n.isGranted;
        _folders = f;
      });
    }
  }

  Future<void> _grantAudio() async {
    final s = context.read<AppServices>();
    final p = await audioPermission(s);
    final r = await p.request();
    if (r.isPermanentlyDenied && mounted) {
      showSnack(context, 'Open system settings to allow music access', action: SnackBarAction(label: 'Settings', onPressed: openAppSettings));
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = context.read<AppServices>();
    return Scaffold(
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(24), children: [
          const SizedBox(height: 24),
          const Align(alignment: Alignment.centerLeft, child: BrandTile(size: 84)),
          const SizedBox(height: 20),
          Text('Welcome to ${Brand.name}', style: t.textTheme.headlineLarge),
          const SizedBox(height: 4),
          Text(Brand.tagline, style: t.textTheme.titleMedium?.copyWith(color: t.colorScheme.primary)),
          const SizedBox(height: 12),
          Text('Play your local music, download from many sources, and let the app tag, cover and add lyrics for you.', style: t.textTheme.bodyLarge),
          const SizedBox(height: 24),
          _step(context, done: _audio, icon: Icons.audiotrack, title: 'Access your music', body: 'Needed to list and play the audio files on this device.', action: _audio ? null : FilledButton(onPressed: _grantAudio, child: const Text('Allow'))),
          _step(context, done: _notif, icon: Icons.notifications_outlined, title: 'Notifications', body: 'Playback controls, download progress and new-release alerts.', action: _notif ? null : OutlinedButton(onPressed: () async {
                await Permission.notification.request();
                await _refresh();
              }, child: const Text('Allow'))),
          _step(context, done: _folders > 0, icon: Icons.folder_open, title: 'Extra folders (optional)', body: 'SD cards or folders the system scanner does not index.', action: OutlinedButton(onPressed: () async {
                await s.bridges.mediaStore.pickFolder();
                await _refresh();
              }, child: Text(_folders == 0 ? 'Add folder' : '$_folders added · add another'))),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _audio
                ? () async {
                    await s.settings.setOnboardingDone(true);
                    widget.onDone();
                  }
                : null,
            child: const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Text('Start')),
          ),
          if (!_audio) Padding(padding: const EdgeInsets.only(top: 8), child: Text('Allow music access to continue.', style: t.textTheme.bodySmall, textAlign: TextAlign.center)),
        ]),
      ),
    );
  }

  Widget _step(BuildContext context, {required bool done, required IconData icon, required String title, required String body, Widget? action}) {
    final t = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          CircleAvatar(backgroundColor: done ? Colors.green.withValues(alpha: 0.2) : t.colorScheme.primaryContainer, child: Icon(done ? Icons.check : icon, color: done ? Colors.green : null)),
          const SizedBox(width: 16),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: t.textTheme.titleMedium), Text(body, style: t.textTheme.bodySmall)])),
          if (action != null) action,
        ]),
      ),
    );
  }
}
