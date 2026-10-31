import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/app_services.dart';
import '../core/models/library_models.dart';
import '../features/downloader/source_detect.dart';
import '../platform/bridges.dart';
import 'screens/dashboard/dashboard_screen.dart';
import 'screens/downloads_screen.dart';
import 'screens/home_screen.dart';
import 'screens/library_screen.dart';
import 'screens/search_screen.dart';
import 'widgets/common.dart';
import 'widgets/kit.dart';
import 'widgets/mini_player.dart';

/// Bottom bar + always-on mini player, share-intent handling, global snackbars.
class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _index = 0;
  final List<StreamSubscription<dynamic>> _subs = [];

  @override
  void initState() {
    super.initState();
    final s = context.read<AppServices>();
    _subs.add(s.player.errors.listen((e) {
      if (mounted) showSnack(context, e);
    }));
    _subs.add(s.downloads.events.listen((e) {
      if (!mounted) return;
      if (e.kind == 'failed') showSnack(context, 'Download failed: ${e.message}', action: SnackBarAction(label: 'View', onPressed: () => setState(() => _index = 3)));
    }));
    _subs.add(s.bridges.system.shares.listen(_onShare));
    s.bridges.system.takeInitialShare().then((v) {
      if (v != null) _onShare(v);
    }).catchError((Object _) {});
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  Future<void> _onShare(SharedContent c) async {
    final s = context.read<AppServices>();
    if (c.type == 'audio') {
      final name = Uri.decodeComponent(c.value.split('/').last);
      await s.player.playMediaItems([MediaItem(id: c.value, title: name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name)]);
      return;
    }
    final url = extractUrl(c.value);
    if (url == null) {
      if (mounted) showSnack(context, 'No link found in the shared text');
      return;
    }
    if (!mounted) return;
    setState(() => _index = 3);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (mounted) await showAddLinkDialog(context, initial: url);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    final pages = <Widget>[
      HomeScreen(goTo: (i) => setState(() => _index = i)),
      const SearchScreen(),
      const LibraryScreen(),
      const DownloadsScreen(),
      const DashboardScreen(),
    ];
    return PopScope(
      canPop: _index == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _index = 0);
      },
      child: Scaffold(
        // Content scrolls under the bar; its height reaches the tabs as bottom padding.
        extendBody: true,
        body: IndexedStack(index: _index, children: pages),
        bottomNavigationBar: Column(mainAxisSize: MainAxisSize.min, children: [
          const MiniPlayer(),
          StreamBuilder<List<DownloadJob>>(
            stream: s.jobs.watchAll(),
            builder: (context, snap) {
              final active = (snap.data ?? const <DownloadJob>[]).where((j) => j.status.isActive).length;
              return BottomBar(
                selectedIndex: _index,
                onSelect: (i) => setState(() => _index = i),
                items: [
                  const DockItem('Home', Icons.home_outlined, Icons.home_filled),
                  const DockItem('Search', Icons.search_rounded, Icons.manage_search_rounded),
                  const DockItem('Your Library', Icons.library_music_outlined, Icons.library_music),
                  DockItem('Downloads', Icons.download_for_offline_outlined, Icons.download_for_offline, badge: active),
                  const DockItem('Dashboard', Icons.space_dashboard_outlined, Icons.space_dashboard),
                ],
              );
            },
          ),
        ]),
      ),
    );
  }
}
