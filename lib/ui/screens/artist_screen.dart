import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_services.dart';
import '../../core/library/smart_rules.dart';
import '../../core/models/library_models.dart';
import '../../core/models/track.dart';
import '../../features/integrations/artist_info_service.dart';
import '../../features/integrations/metadata_clients.dart';
import '../../features/metadata/musicbrainz_client.dart';
import '../widgets/common.dart';
import '../widgets/cover_art.dart';
import '../widgets/track_widgets.dart';
import 'album_screen.dart';
import 'dashboard/artist_editor.dart';

class ArtistScreen extends StatefulWidget {
  const ArtistScreen({super.key, required this.artistId});
  final int artistId;

  @override
  State<ArtistScreen> createState() => _ArtistScreenState();
}

class _ArtistScreenState extends State<ArtistScreen> {
  bool _bioExpanded = false;
  ArtistLinks? _links;
  ({List<MbReleaseGroup> owned, List<MbReleaseGroup> missing})? _disco;
  bool _refreshed = false;

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    return Scaffold(
      body: StreamBuilder<({Artist? artist, List<Album> albums, List<Track> top})>(
        stream: s.db.watch(() async => (
              artist: await s.repo.artistById(widget.artistId),
              albums: await s.repo.albums(artistId: widget.artistId, orderBy: 'a.year DESC, a.title COLLATE NOCASE'),
              top: await s.repo.tracks(artistId: widget.artistId, sort: TrackSort.playCount, descending: true, limit: 200),
            )),
        builder: (context, snap) {
          final d = snap.data;
          if (d == null) return const Center(child: CircularProgressIndicator());
          final artist = d.artist;
          if (artist == null) return const EmptyState(icon: Icons.person_off, title: 'Artist not found');
          if (!_refreshed) {
            _refreshed = true;
            s.artistInfo.refresh(artist).then((a) async {
              final l = await s.artistInfo.links(a);
              if (mounted) setState(() => _links = l);
            });
          }
          final t = Theme.of(context);
          final tracks = d.top;
          return CustomScrollView(slivers: [
            SliverAppBar(
              expandedHeight: 300,
              pinned: true,
              flexibleSpace: FlexibleSpaceBar(
                title: Text(artist.name, style: const TextStyle(shadows: [Shadow(blurRadius: 8, color: Colors.black54)])),
                background: Stack(fit: StackFit.expand, children: [
                  CoverArt(artistId: artist.id, seed: artist.name, size: 600, radius: 0),
                  const DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black54]))),
                ]),
              ),
              actions: [
                IconButton(
                  tooltip: artist.followed ? 'Stop release alerts' : 'Alert me about new releases',
                  icon: Icon(artist.followed ? Icons.notifications_active : Icons.notifications_none),
                  onPressed: () async {
                    await s.repo.updateArtist(artist.id, followed: !artist.followed);
                    if (context.mounted) showSnack(context, artist.followed ? 'Release alerts off' : 'You will be notified about new releases');
                  },
                ),
                IconButton(tooltip: 'Edit artist', icon: const Icon(Icons.edit_outlined), onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ArtistEditorScreen(artistId: artist.id)))),
                IconButton(tooltip: 'Refresh info', icon: const Icon(Icons.refresh), onPressed: () async {
                  await s.artistInfo.refresh(artist, force: true);
                  if (context.mounted) showSnack(context, 'Artist info refreshed');
                }),
              ],
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    FilledButton.icon(onPressed: tracks.isEmpty ? null : () => s.player.playTracks(tracks), icon: const Icon(Icons.play_arrow), label: const Text('Play')),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(onPressed: tracks.isEmpty ? null : () => s.player.playTracks(tracks, shuffle: true), icon: const Icon(Icons.shuffle), label: const Text('Shuffle')),
                  ]),
                  if (artist.bio != null) ...[
                    const SizedBox(height: 16),
                    AnimatedCrossFade(
                      duration: const Duration(milliseconds: 200),
                      crossFadeState: _bioExpanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
                      firstChild: Text(artist.bio!, maxLines: 4, overflow: TextOverflow.ellipsis),
                      secondChild: Text(artist.bio!),
                    ),
                    Row(children: [
                      TextButton(onPressed: () => setState(() => _bioExpanded = !_bioExpanded), child: Text(_bioExpanded ? 'Less' : 'More')),
                      const Spacer(),
                      if (artist.bioSource != null) Text('via ${artist.bioSource}', style: t.textTheme.labelSmall),
                    ]),
                  ],
                  if (_links != null && !_links!.isEmpty)
                    Wrap(spacing: 8, children: [
                      for (final e in _links!.links.entries)
                        ActionChip(avatar: const Icon(Icons.open_in_new, size: 16), label: Text(_label(e.key)), onPressed: () => launchUrl(Uri.parse(e.value), mode: LaunchMode.externalApplication)),
                    ]),
                ]),
              ),
            ),
            if (d.albums.isNotEmpty) ...[
              const SliverToBoxAdapter(child: SectionHeader('Albums')),
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 190,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: d.albums.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 12),
                    itemBuilder: (context, i) => AlbumCard(album: d.albums[i], width: 140),
                  ),
                ),
              ),
            ],
            const SliverToBoxAdapter(child: SectionHeader('Songs')),
            SliverList.builder(
              itemCount: tracks.length > 25 ? 25 : tracks.length,
              itemBuilder: (context, i) => TrackTile(track: tracks[i], onTap: () => s.player.playTracks(tracks, index: i)),
            ),
            SliverToBoxAdapter(child: _discography(context, artist)),
            const SliverToBoxAdapter(child: SizedBox(height: 120)),
          ]);
        },
      ),
    );
  }

  Widget _discography(BuildContext context, Artist artist) {
    final s = context.read<AppServices>();
    if (artist.mbArtistId == null) return const SizedBox.shrink();
    if (_disco == null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: OutlinedButton.icon(
          icon: const Icon(Icons.library_music_outlined),
          label: const Text('Show discography & missing albums'),
          onPressed: () async {
            try {
              final d = await s.artistInfo.discography(artist);
              if (mounted) setState(() => _disco = d);
            } on Object catch (e) {
              if (mounted) showSnack(context, 'Could not load discography: $e');
            }
          },
        ),
      );
    }
    final d = _disco!;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionHeader('Missing albums (${d.missing.length})'),
      for (final g in d.missing)
        ListTile(
          leading: const Icon(Icons.album_outlined),
          title: Text(g.title),
          subtitle: Text('${g.year ?? ''} ${g.primaryType ?? ''}'.trim()),
          trailing: IconButton(
            tooltip: 'Find and download',
            icon: const Icon(Icons.download),
            onPressed: () async {
              final w = WishTrack(artist: artist.name, title: g.title);
              final id = await s.wishlist.add(w, origin: 'discography');
              if (context.mounted) showSnack(context, 'Added "${g.title}" to the wishlist (#$id) - search it in the Search tab');
            },
          ),
        ),
      if (d.missing.isEmpty) const ListTile(title: Text('You have every studio album.')),
    ]);
  }

  String _label(String type) => switch (type) {
        'official homepage' => 'Website',
        'social network' => 'Social',
        _ => type.isEmpty ? type : '${type[0].toUpperCase()}${type.substring(1)}',
      };
}

/// Cover + title + artist tile used in grids and carousels.
class AlbumCard extends StatelessWidget {
  const AlbumCard({super.key, required this.album, this.width});
  final Album album;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AlbumScreen(albumId: album.id))),
      child: SizedBox(
        width: width,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          LayoutBuilder(builder: (context, c) => CoverArt(albumId: album.id, seed: album.title, size: width ?? c.maxWidth, radius: 12)),
          const SizedBox(height: 6),
          Text(album.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.titleSmall),
          Text(album.displayArtist, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}
