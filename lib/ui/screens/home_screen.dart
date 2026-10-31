import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/app_services.dart';
import '../../core/library/smart_rules.dart';
import '../../core/models/track.dart';
import '../../features/library/library_scanner.dart';
import '../../features/playback/media_items.dart';
import '../widgets/brand_logo.dart';
import '../widgets/common.dart';
import '../widgets/cover_art.dart';
import '../widgets/kit.dart';
import '../widgets/track_widgets.dart';
import 'artist_screen.dart';
import 'discover_screens.dart';
import 'downloads_screen.dart';
import 'identify_screens.dart';
import 'library_screen.dart';
import 'settings_screen.dart';

typedef _HomeData = ({
  int count,
  List<Track> recent,
  List<Track> added,
  List<Track> top,
  List<({int id, String name, int count})> artists,
  int review,
});

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.goTo});

  /// Switch the shell's tab (0 home, 1 search, 2 library, 3 downloads).
  final ValueChanged<int> goTo;

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () => s.scanner.scan(force: false),
        child: StreamBuilder<_HomeData>(
          stream: s.db.watch(() async => (
                count: await s.repo.trackCount(),
                recent: await s.repo.recentlyPlayed(limit: 12),
                added: await s.repo.recentlyAdded(limit: 12),
                top: await s.repo.mostPlayed(limit: 10),
                artists: await s.repo.topArtists(limit: 10),
                review: (await s.repo.unidentified()).length,
              )),
          builder: (context, snap) {
            final d = snap.data;
            if (d == null) return const Loader();
            return Stack(children: [
              // A wash of the accent behind the top of the page.
              Container(
                height: 320,
                decoration: BoxDecoration(
                  gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color.alphaBlend(scheme.primary.withValues(alpha: 0.22), scheme.surface), scheme.surface]),
                ),
              ),
              ListView(padding: EdgeInsets.only(bottom: bottomClearance(context)), children: [
                _header(context),
                StreamBuilder<ScanProgress>(
                  stream: s.scanner.progress,
                  builder: (context, p) {
                    final sp = p.data;
                    if (sp == null || sp.phase == 'done') return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(sp.phase == 'reading' ? 'Scanning library · ${sp.done}/${sp.total}' : 'Scanning library…', style: Theme.of(context).textTheme.labelMedium),
                        const SizedBox(height: 6),
                        ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(minHeight: 3, value: sp.total > 0 ? sp.done / sp.total : null)),
                      ]),
                    );
                  },
                ),
                ListenableBuilder(
                  listenable: s.downloads,
                  builder: (context, _) => s.downloads.activeCount == 0
                      ? const SizedBox.shrink()
                      : _Notice(
                          icon: Icons.downloading_rounded,
                          title: '${s.downloads.activeCount} download${s.downloads.activeCount == 1 ? '' : 's'} in progress',
                          onTap: () => goTo(3),
                        ),
                ),
                if (d.review > 0 && d.count > 0)
                  _Notice(
                    icon: Icons.auto_fix_high_rounded,
                    title: '${d.review} songs have incomplete tags',
                    subtitle: 'Identify them with AcoustID + MusicBrainz',
                    onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const FixTagsScreen())),
                  ),
                if (d.count == 0) _firstRun(context, s) else _QuickGrid(data: d),
                if (d.added.isNotEmpty) ...[const SectionHeader('Recently added'), _CoverShelf(tracks: d.added)],
                if (d.artists.isNotEmpty) ...[const SectionHeader('Your top artists'), _ArtistShelf(artists: d.artists)],
                if (d.top.isNotEmpty) ...[const SectionHeader('On repeat'), _CoverShelf(tracks: d.top, subtitle: (t) => '${t.playCount} plays')],
                const SectionHeader('More to explore'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(spacing: 8, runSpacing: 8, children: [
                    _chip(context, Icons.radio_outlined, 'Internet radio', () => const RadioScreen()),
                    _chip(context, Icons.podcasts_rounded, 'Podcasts', () => const PodcastsScreen()),
                    _chip(context, Icons.playlist_add_rounded, 'Import playlist', () => const PlaylistImportScreen()),
                    _chip(context, Icons.bookmark_border_rounded, 'Wishlist', () => const WishlistScreen()),
                    _chip(context, Icons.auto_fix_high_rounded, 'Fix tags', () => const FixTagsScreen()),
                  ]),
                ),
              ]),
            ]);
          },
        ),
      ),
    );
  }

  void _open(BuildContext context, Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  Widget _header(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
        child: Row(children: [
          Tooltip(
            message: 'Settings',
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => _open(context, const SettingsScreen()),
              child: Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: scheme.surfaceContainerHighest, shape: BoxShape.circle),
                child: const BrandMark(size: 24),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                PillChip(label: greeting(), selected: true, onTap: () {}),
                const SizedBox(width: 8),
                PillChip(label: 'Radio', selected: false, onTap: () => _open(context, const RadioScreen())),
                const SizedBox(width: 8),
                PillChip(label: 'Podcasts', selected: false, onTap: () => _open(context, const PodcastsScreen())),
                const SizedBox(width: 8),
                PillChip(label: 'Wishlist', selected: false, onTap: () => _open(context, const WishlistScreen())),
              ]),
            ),
          ),
          IconButton(tooltip: 'Colours & fonts', icon: const Icon(Icons.palette_outlined), onPressed: () => _open(context, const AppearanceScreen())),
        ]),
      ),
    );
  }

  Widget _chip(BuildContext context, IconData icon, String label, Widget Function() page) => PillChip(icon: icon, label: label, selected: false, onTap: () => _open(context, page()));

  Widget _firstRun(BuildContext context, AppServices s) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Let\'s fill your library', style: t.textTheme.headlineLarge),
            const SizedBox(height: 6),
            Text('Scan this device for music, pick a folder, or download something.', style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 16),
            Wrap(spacing: 8, runSpacing: 8, children: [
              PillButton(icon: Icons.refresh_rounded, label: 'Scan device', onPressed: () => s.scanner.scan(force: true)),
              PillButton(
                filled: false,
                icon: Icons.folder_open_rounded,
                label: 'Add folder',
                onPressed: () async {
                  final f = await s.bridges.mediaStore.pickFolder();
                  if (f != null) await s.scanner.scan(force: true);
                },
              ),
              PillButton(filled: false, icon: Icons.search_rounded, label: 'Find music', onPressed: () => goTo(1)),
              PillButton(filled: false, icon: Icons.add_link_rounded, label: 'Paste a link', onPressed: () => showAddLinkDialog(context)),
            ]),
          ]),
        ),
      ),
    );
  }
}

/// Two columns of compact tiles: favourites, shuffle and what you played last.
class _QuickGrid extends StatelessWidget {
  const _QuickGrid({required this.data});
  final _HomeData data;

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    final scheme = Theme.of(context).colorScheme;
    final seen = <int>{};
    final recent = [...data.recent, ...data.added].where((t) => seen.add(t.id)).take(6).toList();
    return StreamBuilder<MediaItem?>(
      stream: s.player.currentItem,
      builder: (context, cur) {
        final currentId = cur.data?.trackId;
        final tiles = <Widget>[
          _QuickTile(
            art: _IconArt(icon: Icons.favorite_rounded, colors: [scheme.primary, Color.lerp(scheme.primary, Colors.white, 0.55)!]),
            title: 'Liked songs',
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => TrackCollectionScreen(title: 'Liked songs', loader: s.repo.lovedTracks))),
          ),
          _QuickTile(
            art: _IconArt(icon: Icons.shuffle_rounded, colors: [scheme.surfaceContainerHighest, scheme.surfaceContainerHigh], iconColor: scheme.primary),
            title: 'Shuffle all',
            onTap: () async {
              final tracks = await s.repo.tracks(sort: TrackSort.random, limit: 500);
              if (tracks.isNotEmpty) await s.player.playTracks(tracks);
            },
          ),
          for (var i = 0; i < recent.length; i++)
            _QuickTile(
              art: CoverArt(track: recent[i], size: 56, radius: 0),
              title: recent[i].title,
              playing: recent[i].id == currentId,
              onTap: () => s.player.playTracks(recent, index: i),
              onLongPress: () => showTrackMenu(context, recent[i]),
            ),
        ];
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(children: [
            for (var r = 0; r < tiles.length; r += 2)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(children: [
                  Expanded(child: tiles[r]),
                  const SizedBox(width: 8),
                  Expanded(child: r + 1 < tiles.length ? tiles[r + 1] : const SizedBox()),
                ]),
              ),
          ]),
        );
      },
    );
  }
}

class _QuickTile extends StatelessWidget {
  const _QuickTile({required this.art, required this.title, required this.onTap, this.onLongPress, this.playing = false});

  final Widget art;
  final String title;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool playing;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Material(
      color: t.colorScheme.onSurface.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(5),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: SizedBox(
          height: 56,
          child: Row(children: [
            SizedBox.square(dimension: 56, child: art),
            const SizedBox(width: 10),
            Expanded(
              child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700, height: 1.2, color: playing ? t.colorScheme.primary : null)),
            ),
            if (playing) const Padding(padding: EdgeInsets.only(right: 10), child: PlayingBars(playing: true, size: 14)),
          ]),
        ),
      ),
    );
  }
}

class _IconArt extends StatelessWidget {
  const _IconArt({required this.icon, required this.colors, this.iconColor = Colors.white});
  final IconData icon;
  final List<Color> colors;
  final Color iconColor;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors)),
        child: Icon(icon, color: iconColor, size: 24),
      );
}

/// A horizontal row of large square covers.
class _CoverShelf extends StatelessWidget {
  const _CoverShelf({required this.tracks, this.subtitle});
  final List<Track> tracks;
  final String Function(Track)? subtitle;

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    final t = Theme.of(context);
    return SizedBox(
      height: 214,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: tracks.length,
        separatorBuilder: (_, _) => const SizedBox(width: 14),
        itemBuilder: (context, i) {
          final tr = tracks[i];
          return GestureDetector(
            onTap: () => s.player.playTracks(tracks, index: i),
            onLongPress: () => showTrackMenu(context, tr),
            child: SizedBox(
              width: 150,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                CoverArt(track: tr, size: 150, radius: 6),
                const SizedBox(height: 8),
                Text(tr.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                Text(subtitle?.call(tr) ?? tr.displayArtist, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              ]),
            ),
          );
        },
      ),
    );
  }
}

class _ArtistShelf extends StatelessWidget {
  const _ArtistShelf({required this.artists});
  final List<({int id, String name, int count})> artists;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return SizedBox(
      height: 178,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: artists.length,
        separatorBuilder: (_, _) => const SizedBox(width: 14),
        itemBuilder: (context, i) {
          final a = artists[i];
          return GestureDetector(
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ArtistScreen(artistId: a.id))),
            child: SizedBox(
              width: 132,
              child: Column(children: [
                CoverArt(artistId: a.id, seed: a.name, size: 132, circle: true),
                const SizedBox(height: 8),
                Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
              ]),
            ),
          );
        },
      ),
    );
  }
}

/// A tappable notice (downloads running, tags to review).
class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.title, required this.onTap, this.subtitle});

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Card(
        child: ListTile(
          leading: Icon(icon, color: scheme.primary),
          title: Text(title),
          subtitle: subtitle == null ? null : Text(subtitle!),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: onTap,
        ),
      ),
    );
  }
}
