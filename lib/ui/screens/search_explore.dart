import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/app_services.dart';
import '../../core/library/smart_rules.dart';
import '../../core/settings/settings_store.dart';
import '../widgets/common.dart';
import '../widgets/cover_art.dart';
import 'discover_screens.dart';
import 'library_screen.dart';

typedef _ExploreData = ({
  int count,
  List<({String name, int count, int? albumId})> genres,
  List<({int decade, int count, int? albumId})> decades,
});

/// What Search shows before you type: your recent searches and ways into your own library
/// (genres, decades, a surprise mix) instead of a store catalogue.
class SearchExplore extends StatelessWidget {
  const SearchExplore({super.key, required this.onSearch});

  /// Runs a search for the given text (recent-search chips).
  final ValueChanged<String> onSearch;

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    final settings = context.watch<SettingsStore>();
    final t = Theme.of(context);
    void open(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    return StreamBuilder<_ExploreData>(
      stream: s.db.watch(() async => (count: await s.repo.trackCount(), genres: await s.repo.genreShelf(), decades: await s.repo.decades())),
      builder: (context, snap) {
        final d = snap.data;
        final recent = settings.recentSearches;
        return ListView(padding: EdgeInsets.only(bottom: bottomClearance(context)), children: [
          if (recent.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 6, 8),
              child: Row(children: [
                Expanded(child: Text('Recent searches', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800))),
                TextButton(onPressed: settings.clearRecentSearches, child: const Text('Clear')),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(spacing: 8, runSpacing: 8, children: [
                for (final q in recent)
                  ActionChip(avatar: const Icon(Icons.history_rounded, size: 16), label: Text(q), onPressed: () => onSearch(q)),
              ]),
            ),
          ],
          _title(context, 'Start browsing'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              Expanded(child: _Tile(title: 'Radio', color: const Color(0xFFD1306C), height: 64, art: const _GlyphArt(Icons.radio_rounded), onTap: () => open(const RadioScreen()))),
              const SizedBox(width: 10),
              Expanded(child: _Tile(title: 'Podcasts', color: const Color(0xFF0F7B6C), height: 64, art: const _GlyphArt(Icons.podcasts_rounded), onTap: () => open(const PodcastsScreen()))),
            ]),
          ),
          if (d != null && d.count > 0) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: _SurpriseTile(onTap: () async {
                final tracks = await s.repo.tracks(sort: TrackSort.random, limit: 50);
                if (tracks.isNotEmpty) await s.player.playTracks(tracks);
              }),
            ),
            if (d.genres.isNotEmpty) ...[
              _title(context, 'Your genres', subtitle: 'From the tags in your library'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  padding: EdgeInsets.zero,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 1.8,
                  children: [
                    for (final g in d.genres)
                      _Tile(
                        title: g.name,
                        subtitle: '${g.count} song${g.count == 1 ? '' : 's'}',
                        color: tileColor(g.name),
                        art: g.albumId == null ? const _GlyphArt(Icons.music_note_rounded) : CoverArt(albumId: g.albumId, seed: g.name, size: 70, radius: 4),
                        onTap: () => open(TrackCollectionScreen(title: g.name, loader: () => s.repo.tracks(genre: g.name))),
                      ),
                  ],
                ),
              ),
            ],
            if (d.decades.isNotEmpty) ...[
              _title(context, 'Through the decades', subtitle: 'Your songs by release year'),
              SizedBox(
                height: 150,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: d.decades.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 10),
                  itemBuilder: (context, i) {
                    final dec = d.decades[d.decades.length - 1 - i]; // newest first
                    final label = decadeLabel(dec.decade);
                    return SizedBox(
                      width: 150,
                      child: _Tile(
                        title: label,
                        big: true,
                        subtitle: '${dec.count} song${dec.count == 1 ? '' : 's'}',
                        color: tileColor('decade${dec.decade}'),
                        art: dec.albumId == null ? const _GlyphArt(Icons.history_edu_rounded) : CoverArt(albumId: dec.albumId, seed: label, size: 70, radius: 4),
                        onTap: () => open(TrackCollectionScreen(title: 'The $label', loader: () => s.repo.tracksInYears(dec.decade, dec.decade + 9))),
                      ),
                    );
                  },
                ),
              ),
            ],
          ],
          if (d != null && d.count == 0)
            const Padding(
              padding: EdgeInsets.only(top: 24),
              child: EmptyState(icon: Icons.travel_explore_rounded, title: 'Find music anywhere', message: 'Search online sources at once, or paste a YouTube, SoundCloud, Bandcamp or Internet Archive link to download it.'),
            ),
        ]);
      },
    );
  }

  Widget _title(BuildContext context, String text, {String? subtitle}) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(text, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
        if (subtitle != null) Text(subtitle, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      ]),
    );
  }
}

/// "1990" -> "90s", "2000" -> "2000s", "1960" -> "60s".
String decadeLabel(int decade) => decade >= 2000 ? '${decade}s' : "${(decade % 100).toString().padLeft(2, '0')}s";

/// A stable, saturated tile colour for a name.
Color tileColor(String seed) {
  var h = 0;
  for (final c in seed.toLowerCase().codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return HSLColor.fromAHSL(1, (h % 360).toDouble(), 0.58, 0.40).toColor();
}

/// A coloured tile with a bold title and a cover tilted into the bottom-right corner.
class _Tile extends StatelessWidget {
  const _Tile({required this.title, required this.color, required this.art, required this.onTap, this.subtitle, this.height, this.big = false});

  final String title;
  final String? subtitle;
  final Color color;
  final Widget art;
  final VoidCallback onTap;
  final double? height;
  final bool big;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return SizedBox(
      height: height,
      child: Material(
        color: color,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Stack(children: [
            Positioned(right: -14, bottom: -8, child: Transform.rotate(angle: 0.44, child: SizedBox.square(dimension: 70, child: art))),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: (big ? t.textTheme.displaySmall : t.textTheme.titleMedium)?.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
                if (subtitle != null) Text(subtitle!, style: t.textTheme.labelMedium?.copyWith(color: Colors.white70)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _GlyphArt extends StatelessWidget {
  const _GlyphArt(this.icon);
  final IconData icon;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.22), borderRadius: BorderRadius.circular(4)),
        child: Icon(icon, color: Colors.white, size: 34),
      );
}

/// A wide accent tile that starts 50 random songs from the library.
class _SurpriseTile extends StatelessWidget {
  const _SurpriseTile({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final scheme = t.colorScheme;
    return Material(
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: Ink(
        decoration: BoxDecoration(gradient: LinearGradient(colors: [scheme.primary, Color.lerp(scheme.primary, scheme.tertiary, 0.6)!])),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Surprise me', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800, color: scheme.onPrimary)),
                  Text('50 random songs from your library', style: t.textTheme.bodySmall?.copyWith(color: scheme.onPrimary.withValues(alpha: 0.8))),
                ]),
              ),
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(color: scheme.onPrimary, shape: BoxShape.circle),
                child: Icon(Icons.shuffle_rounded, color: scheme.primary),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
