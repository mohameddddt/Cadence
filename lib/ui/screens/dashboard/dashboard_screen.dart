import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../app/app_services.dart';
import '../../../app/brand.dart';
import '../../../core/library/library_health.dart';
import '../../../core/models/library_models.dart';
import '../../../features/library/library_scanner.dart';
import '../../widgets/brand_logo.dart';
import '../../widgets/common.dart';
import '../../widgets/kit.dart';
import '../identify_screens.dart';
import 'album_manager.dart';
import 'artist_editor.dart';
import 'artist_manager.dart';
import 'dashboard_widgets.dart';

typedef _Overview = ({LibraryStats stats, List<Album> albums, List<Artist> artists, List<({int id, String name, int count})> top, int unidentified});

/// The library dashboard: how healthy the collection is, what needs fixing, and full
/// management (edit, merge, bulk actions) of artists and albums.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);
  final ValueNotifier<AlbumFilter> _albumFilter = ValueNotifier(AlbumFilter.all);
  final ValueNotifier<ArtistFilter> _artistFilter = ValueNotifier(ArtistFilter.all);
  late final Stream<_Overview> _overview;

  @override
  void initState() {
    super.initState();
    final s = context.read<AppServices>();
    _overview = s.db.watch<_Overview>(
      () async => (
        stats: await s.repo.stats(),
        albums: await s.repo.albums(),
        artists: await s.repo.artists(),
        top: await s.repo.topArtists(limit: 5),
        unidentified: (await s.repo.unidentified()).length,
      ),
    );
  }

  @override
  void dispose() {
    _tabs.dispose();
    _albumFilter.dispose();
    _artistFilter.dispose();
    super.dispose();
  }

  void _showAlbums(AlbumFilter f) {
    _albumFilter.value = f;
    _tabs.animateTo(2);
  }

  void _showArtists(ArtistFilter f) {
    _artistFilter.value = f;
    _tabs.animateTo(1);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: screenTitleHeight,
        title: const ScreenTitle('Dashboard', eyebrow: 'Library health'),
        actions: [
          IconButton(
            tooltip: 'Rescan library',
            icon: const Icon(Icons.refresh),
            onPressed: () async {
              final s = context.read<AppServices>();
              showSnack(context, 'Scanning…');
              final r = await s.scanner.scan();
              if (context.mounted) showSnack(context, '${r.total} songs (${r.added} new, ${r.removed} removed)');
            },
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          tabs: const [
            Tab(text: 'Overview'),
            Tab(text: 'Artists'),
            Tab(text: 'Albums'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          StreamBuilder<_Overview>(
            stream: _overview,
            builder: (context, snap) {
              final d = snap.data;
              if (d == null) return const Center(child: CircularProgressIndicator());
              return _OverviewTab(data: d, onAlbums: _showAlbums, onArtists: _showArtists, goToTab: (i) => _tabs.animateTo(i));
            },
          ),
          ArtistManager(filter: _artistFilter),
          AlbumManager(filter: _albumFilter),
        ],
      ),
    );
  }
}

class _OverviewTab extends StatelessWidget {
  const _OverviewTab({required this.data, required this.onAlbums, required this.onArtists, required this.goToTab});

  final _Overview data;
  final ValueChanged<AlbumFilter> onAlbums;
  final ValueChanged<ArtistFilter> onArtists;
  final ValueChanged<int> goToTab;

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    final t = Theme.of(context);
    final st = data.stats;
    if (st.tracks == 0) {
      return EmptyState(
        icon: Icons.dashboard_outlined,
        title: 'Nothing to manage yet',
        message: 'Scan this device or download some music, and your library shows up here.',
        action: FilledButton.icon(onPressed: () => s.scanner.scan(force: true), icon: const Icon(Icons.refresh), label: const Text('Scan now')),
      );
    }
    return ListenableBuilder(
      listenable: s.coverCache,
      builder: (context, _) {
        final noCover = data.albums.where((a) => s.coverCache.albumCover(a.id) == null).length;
        final noYear = data.albums.where((a) => a.year == null).length;
        final noArtist = data.albums.where((a) => a.artistName == null || a.artistName!.isEmpty).length;
        final dupAlbums = duplicateAlbumIds(data.albums).length;
        final noPhoto = data.artists.where((a) => s.coverCache.artistImage(a.id) == null).length;
        final noBio = data.artists.where((a) => a.bio == null || a.bio!.trim().isEmpty).length;
        final dupArtists = duplicateArtistIds(data.artists).length;
        final issues = noCover + noYear + noArtist + dupAlbums + noPhoto + noBio + dupArtists;
        return ListView(
          padding: EdgeInsets.only(bottom: bottomClearance(context)),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: _Hero(stats: st),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                children: [
                  Expanded(
                    child: StatTile(icon: Icons.album_outlined, label: 'Albums', value: formatCount(data.albums.length), onTap: () => goToTab(2)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: StatTile(icon: Icons.person_outline, label: 'Artists', value: formatCount(data.artists.length), onTap: () => goToTab(1)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: StatTile(icon: Icons.schedule, label: 'Of music', value: formatTotalDuration(st.durationMs)),
                  ),
                ],
              ),
            ),
            const SectionHeader('Tag health'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text('${(st.identifiedRatio * 100).round()}%', style: t.textTheme.headlineMedium?.copyWith(fontFeatures: tabularFigures)),
                          const SizedBox(width: 8),
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text('of songs matched to MusicBrainz', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      MeterBar(value: st.identifiedRatio, height: 10, semanticsLabel: 'Songs matched to MusicBrainz'),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              data.unidentified == 0
                                  ? 'Every song is identified.'
                                  : '${plural(data.unidentified, 'song')} still ${data.unidentified == 1 ? 'needs' : 'need'} tags · ${formatBytes(st.sizeBytes)} in total',
                              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                            ),
                          ),
                          if (data.unidentified > 0)
                            TextButton(
                              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const FixTagsScreen())),
                              child: const Text('Fix tags'),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SectionHeader(
              'Needs attention',
              trailing: issues == 0
                  ? null
                  : Text(
                      plural(issues, 'issue'),
                      style: t.textTheme.labelLarge?.copyWith(color: t.colorScheme.onSurfaceVariant, fontFeatures: tabularFigures),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Card(
                child: Column(
                  children: [
                    AttentionTile(
                      icon: Icons.hide_image_outlined,
                      title: 'Albums without a cover',
                      subtitle: 'Find or choose artwork',
                      count: noCover,
                      onTap: () => onAlbums(AlbumFilter.noCover),
                    ),
                    AttentionTile(
                      icon: Icons.event_busy_outlined,
                      title: 'Albums without a year',
                      subtitle: 'Fill in the release year',
                      count: noYear,
                      onTap: () => onAlbums(AlbumFilter.noYear),
                    ),
                    AttentionTile(
                      icon: Icons.person_off_outlined,
                      title: 'Albums without an artist',
                      subtitle: 'Set an album artist',
                      count: noArtist,
                      onTap: () => onAlbums(AlbumFilter.noArtist),
                    ),
                    AttentionTile(
                      icon: Icons.difference_outlined,
                      title: 'Possible duplicate albums',
                      subtitle: 'Same title and artist, merge them',
                      count: dupAlbums,
                      onTap: () => onAlbums(AlbumFilter.duplicates),
                    ),
                    AttentionTile(
                      icon: Icons.face_retouching_off,
                      title: 'Artists without a photo',
                      subtitle: 'Look one up or pick your own',
                      count: noPhoto,
                      onTap: () => onArtists(ArtistFilter.noPhoto),
                    ),
                    AttentionTile(icon: Icons.notes, title: 'Artists without a bio', subtitle: 'Look one up or write your own', count: noBio, onTap: () => onArtists(ArtistFilter.noBio)),
                    AttentionTile(
                      icon: Icons.people_alt_outlined,
                      title: 'Possible duplicate artists',
                      subtitle: 'Different spellings of one name',
                      count: dupArtists,
                      onTap: () => onArtists(ArtistFilter.duplicates),
                    ),
                  ],
                ),
              ),
            ),
            if (data.top.isNotEmpty) ...[
              const SectionHeader('Top artists'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: RankedBars(
                      rows: data.top,
                      onTap: (id) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ArtistEditorScreen(artistId: id))),
                    ),
                  ),
                ),
              ),
            ],
            const SectionHeader('Shortcuts'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ActionChip(
                    avatar: const Icon(Icons.shuffle, size: 18),
                    label: const Text('Shuffle everything'),
                    onPressed: () async {
                      final all = await s.repo.tracks();
                      if (all.isNotEmpty) await s.player.playTracks(all, shuffle: true);
                    },
                  ),
                  ActionChip(
                    avatar: const Icon(Icons.auto_fix_high, size: 18),
                    label: const Text('Fix tags'),
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const FixTagsScreen())),
                  ),
                  ActionChip(
                    avatar: const Icon(Icons.favorite_border, size: 18),
                    label: Text('${formatCount(st.loved)} loved'),
                    onPressed: () async {
                      final loved = await s.repo.lovedTracks();
                      if (loved.isNotEmpty) await s.player.playTracks(loved);
                    },
                  ),
                ],
              ),
            ),
            StreamBuilder<ScanProgress>(
              stream: s.scanner.progress,
              builder: (context, p) {
                final sp = p.data;
                if (sp == null || sp.phase == 'done') return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(sp.phase == 'reading' ? 'Scanning library… ${sp.done}/${sp.total}' : 'Scanning library…', style: t.textTheme.bodySmall),
                      const SizedBox(height: 4),
                      LinearProgressIndicator(value: sp.total > 0 ? sp.done / sp.total : null),
                    ],
                  ),
                );
              },
            ),
          ],
        );
      },
    );
  }
}

/// Ink hero card: the song count, large in the display face, with the mark as a watermark.
class _Hero extends StatelessWidget {
  const _Hero({required this.stats});
  final LibraryStats stats;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final scheme = t.colorScheme;
    final ink = scheme.onInverseSurface;
    return ClipRRect(
      borderRadius: BorderRadius.circular(28),
      child: ColoredBox(
        color: scheme.inverseSurface,
        child: Stack(
          children: [
            Positioned(
              right: -34,
              top: -20,
              child: Opacity(
                opacity: 0.22,
                child: CustomPaint(size: const Size.square(190), painter: BrandMarkPainter(mono: scheme.primary)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Eyebrow('Your library', color: ink.withValues(alpha: 0.7)),
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(formatCount(stats.tracks), style: t.textTheme.displayLarge?.copyWith(color: ink, fontFeatures: tabularFigures)),
                      const SizedBox(width: 8),
                      Text(stats.tracks == 1 ? 'song' : 'songs', style: t.textTheme.titleMedium?.copyWith(color: ink.withValues(alpha: 0.85))),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(Brand.tagline, style: t.textTheme.labelLarge?.copyWith(color: scheme.inversePrimary)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
