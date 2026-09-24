import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/app_services.dart';
import '../../core/models/library_models.dart';
import '../../core/models/track.dart';
import '../../features/library/library_scanner.dart';
import '../widgets/brand_logo.dart';
import '../widgets/common.dart';
import '../widgets/cover_art.dart';
import '../widgets/track_widgets.dart';
import 'discover_screens.dart';
import 'downloads_screen.dart';
import 'identify_screens.dart';
import 'settings_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.goTo});

  /// Switch the shell's tab (0 home, 1 library, 2 search, 3 downloads).
  final ValueChanged<int> goTo;

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    return Scaffold(
      appBar: AppBar(
        title: const BrandLockup(),
        actions: [
          IconButton(tooltip: 'Settings', icon: const Icon(Icons.settings_outlined), onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()))),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => s.scanner.scan(force: false),
        child: StreamBuilder<
            ({
              int count,
              List<Track> recent,
              List<Track> added,
              List<Track> top,
              int review,
            })>(
          stream: s.db.watch(() async => (
                count: await s.repo.trackCount(),
                recent: await s.repo.recentlyPlayed(limit: 12),
                added: await s.repo.recentlyAdded(limit: 12),
                top: await s.repo.mostPlayed(limit: 5),
                review: (await s.repo.unidentified()).length,
              )),
          builder: (context, snap) {
            final d = snap.data;
            if (d == null) return const Center(child: CircularProgressIndicator());
            return ListView(padding: const EdgeInsets.only(bottom: 120), children: [
              StreamBuilder<ScanProgress>(
                stream: s.scanner.progress,
                builder: (context, p) {
                  final sp = p.data;
                  if (sp == null || sp.phase == 'done') return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(sp.phase == 'reading' ? 'Scanning library… ${sp.done}/${sp.total}' : 'Scanning library…', style: Theme.of(context).textTheme.bodySmall),
                      const SizedBox(height: 4),
                      LinearProgressIndicator(value: sp.total > 0 ? sp.done / sp.total : null),
                    ]),
                  );
                },
              ),
              ListenableBuilder(
                listenable: s.downloads,
                builder: (context, _) => s.downloads.activeCount == 0
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                        child: Card(
                          child: ListTile(
                            leading: const Icon(Icons.downloading),
                            title: Text('${s.downloads.activeCount} download${s.downloads.activeCount == 1 ? '' : 's'} in progress'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => goTo(3),
                          ),
                        ),
                      ),
              ),
              if (d.count == 0) _firstRun(context, s),
              if (d.review > 0 && d.count > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Card(
                    child: ListTile(
                      leading: const Icon(Icons.auto_fix_high),
                      title: Text('${d.review} songs have incomplete tags'),
                      subtitle: const Text('Identify them with AcoustID + MusicBrainz'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const FixTagsScreen())),
                    ),
                  ),
                ),
              if (d.recent.isNotEmpty) ...[const SectionHeader('Continue listening'), _carousel(context, d.recent)],
              if (d.added.isNotEmpty) ...[const SectionHeader('Recently added'), _carousel(context, d.added)],
              if (d.top.isNotEmpty) ...[
                const SectionHeader('Most played'),
                for (var i = 0; i < d.top.length; i++) TrackTile(track: d.top[i], onTap: () => s.player.playTracks(d.top, index: i)),
              ],
              const SectionHeader('Discover'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Wrap(spacing: 8, runSpacing: 8, children: [
                  _chip(context, Icons.radio, 'Internet radio', () => const RadioScreen()),
                  _chip(context, Icons.podcasts, 'Podcasts', () => const PodcastsScreen()),
                  _chip(context, Icons.playlist_add, 'Import playlist', () => const PlaylistImportScreen()),
                  _chip(context, Icons.bookmark_border, 'Wishlist', () => const WishlistScreen()),
                  _chip(context, Icons.auto_fix_high, 'Fix tags', () => const FixTagsScreen()),
                ]),
              ),
            ]);
          },
        ),
      ),
    );
  }

  Widget _chip(BuildContext context, IconData icon, String label, Widget Function() page) => ActionChip(
        avatar: Icon(icon, size: 18),
        label: Text(label),
        onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page())),
      );

  Widget _firstRun(BuildContext context, AppServices s) => Padding(
        padding: const EdgeInsets.all(16),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [const BrandMark(size: 28), const SizedBox(width: 10), Text('Welcome to Cadence', style: Theme.of(context).textTheme.titleLarge)]),
              const SizedBox(height: 8),
              const Text('Your library is empty. Scan this device for music, pick a folder, or download something.'),
              const SizedBox(height: 16),
              Wrap(spacing: 8, runSpacing: 8, children: [
                FilledButton.icon(onPressed: () => s.scanner.scan(force: true), icon: const Icon(Icons.refresh), label: const Text('Scan device')),
                OutlinedButton.icon(
                  onPressed: () async {
                    final f = await s.bridges.mediaStore.pickFolder();
                    if (f != null) await s.scanner.scan(force: true);
                  },
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Add folder'),
                ),
                OutlinedButton.icon(onPressed: () => goTo(2), icon: const Icon(Icons.search), label: const Text('Find music')),
                OutlinedButton.icon(onPressed: () => showAddLinkDialog(context), icon: const Icon(Icons.add_link), label: const Text('Paste a link')),
              ]),
            ]),
          ),
        ),
      );

  Widget _carousel(BuildContext context, List<Track> tracks) {
    final s = context.read<AppServices>();
    return SizedBox(
      height: 178,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: tracks.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, i) {
          final t = tracks[i];
          return InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => s.player.playTracks(tracks, index: i),
            onLongPress: () => showTrackMenu(context, t),
            child: SizedBox(
              width: 128,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                CoverArt(track: t, size: 128, radius: 12),
                const SizedBox(height: 6),
                Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleSmall),
                Text(t.displayArtist, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
              ]),
            ),
          );
        },
      ),
    );
  }
}

/// Keeps Album import used where carousels of albums may be added later.
typedef AlbumList = List<Album>;
