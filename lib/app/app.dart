import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../core/settings/settings_store.dart';
import '../features/downloader/download_manager.dart';
import '../ui/screens/onboarding_screen.dart';
import '../ui/shell.dart';
import '../ui/widgets/brand_logo.dart';
import 'app_services.dart';
import 'brand.dart';
import 'cover_cache.dart';
import 'theme.dart';

/// Root widget: providers, themes and the onboarding gate.
class MusicApp extends StatelessWidget {
  const MusicApp({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<AppServices>.value(value: services),
        ChangeNotifierProvider<SettingsStore>.value(value: services.settings),
        ChangeNotifierProvider<DownloadManager>.value(value: services.downloads),
        ChangeNotifierProvider<CoverCache>.value(value: services.coverCache),
      ],
      child: Consumer<SettingsStore>(
        builder: (context, settings, _) => DynamicColorBuilder(
          builder: (light, dark) {
            final t = AppTheme.build(dynamicLightPrimary: light?.primary, dynamicDarkPrimary: dark?.primary, settings: settings);
            return MaterialApp(
              title: Brand.name,
              debugShowCheckedModeBanner: false,
              theme: t.light,
              darkTheme: t.dark,
              themeMode: AppTheme.modeOf(settings.themePreference),
              home: _Gate(services: services),
            );
          },
        ),
      ),
    );
  }
}

class _Gate extends StatefulWidget {
  const _Gate({required this.services});
  final AppServices services;

  @override
  State<_Gate> createState() => _GateState();
}

class _GateState extends State<_Gate> with WidgetsBindingObserver {
  bool? _ready;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from the system settings after granting access.
    if (state == AppLifecycleState.resumed && _ready == false) _check();
  }

  Future<bool> _hasAudioPermission() async {
    try {
      final sdk = await widget.services.bridges.system.sdkInt();
      final p = sdk >= 33 ? Permission.audio : Permission.storage;
      return (await p.status).isGranted;
    } on Object {
      return true; // not on Android (tests / desktop)
    }
  }

  Future<void> _check() async {
    final granted = await _hasAudioPermission();
    final ready = granted && widget.services.settings.onboardingDone;
    if (!mounted) return;
    setState(() => _ready = ready);
    if (ready) widget.services.start(hasLibraryPermission: true);
  }

  @override
  Widget build(BuildContext context) {
    final ready = _ready;
    if (ready == null) return const Scaffold(backgroundColor: Brand.ink900, body: Center(child: BrandTile(size: 96)));
    if (!ready) {
      return OnboardingScreen(onDone: () {
        setState(() => _ready = true);
        widget.services.start(hasLibraryPermission: true);
      });
    }
    return const Shell();
  }
}
