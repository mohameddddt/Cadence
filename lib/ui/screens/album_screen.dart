import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/app_services.dart';
import '../../core/library/album_grouping.dart';
import '../../core/library/smart_rules.dart';
import '../../core/models/library_models.dart';
import '../../core/models/track.dart';
import '../../features/cover/cover_providers.dart';
import '../../features/integrations/metadata_clients.dart';
import '../../features/library/library_editor.dart';
import '../widgets/common.dart';
import '../widgets/cover_art.dart';
import '../widgets/cover_tint.dart';
import '../widgets/kit.dart';
import '../widgets/track_widgets.dart';
import 'artist_screen.dart';
import 'dashboard/album_editor.dart';
import 'identify_screens.dart';

class AlbumScreen extends StatelessWidget {
  const AlbumScreen({super.key, required this.albumId});
  final int albumId;

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    return Scaffold(
      body: StreamBuilder<({Album? album, List<Track> tracks})>(
        stream: s.db.watch(() async => (album: await s.repo.albumById(albumId), tracks: await s.repo.tracks(albumId: albumId, sort: TrackSort.album))),
        builder: (context, snap) {
          final data = snap.data;
          if (data == null) return const Center(child: CircularProgressIndicator());
          final album = data.album;
          if (album == null) return const EmptyState(icon: Icons.album, title: 'Album not found');
          final tracks = data.tracks;
          final t = Theme.of(context);
          final discs = tracks.map((e) => e.discNo ?? 1).toSet();
          return CoverTintBuilder(
            path: s.coverCache.albumCover(album.id),
            builder: (context, tint) {
              final scheme = t.colorScheme;
              final top = tint == null ? scheme.surfaceContainerHighest : CoverTint.shade(tint, t.brightness == Brightness.dark ? 0.32 : 0.78);
              return CustomScrollView(slivers: [
            SliverAppBar(
              pinned: true,
              backgroundColor: top,
              actions: [
                PopupMenuButton<String>(
                  onSelected: (v) => _menu(context, v, album, tracks),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'edit', child: Text('Edit album…')),
                    PopupMenuItem(value: 'cover', child: Text('Change cover…')),
                    PopupMenuItem(value: 'fix', child: Text('Identify album (fix tags)')),
                    PopupMenuItem(value: 'missing', child: Text('Download missing tracks')),
                    PopupMenuItem(value: 'queue', child: Text('Add to queue')),
                    PopupMenuItem(value: 'playlist', child: Text('Add to playlist…')),
                  ],
                ),
              ],
            ),
            SliverToBoxAdapter(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [top, scheme.surface])),
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Center(child: CoverArt(albumId: album.id, seed: album.title, size: 240, radius: 4)),
                  const SizedBox(height: 20),
                  Text(album.title, style: t.textTheme.headlineLarge),
                  const SizedBox(height: 8),
                  InkWell(
                    onTap: album.artistId == null ? null : () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ArtistScreen(artistId: album.artistId!))),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (album.artistId != null) ...[CoverArt(artistId: album.artistId, seed: album.displayArtist, size: 24, circle: true), const SizedBox(width: 8)],
                      Text(album.displayArtist, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                    ]),
                  ),
                  const SizedBox(height: 6),
                  Text(['Album', if (album.year != null) '${album.year}', '${tracks.length} songs', formatMs(album.durationMs)].join(' · '), style: t.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 4),
                  Row(children: [
                    IconButton(tooltip: 'Add to playlist', icon: Icon(Icons.add_circle_outline_rounded, color: scheme.onSurfaceVariant), onPressed: tracks.isEmpty ? null : () => _menu(context, 'playlist', album, tracks)),
                    IconButton(tooltip: 'Add to queue', icon: Icon(Icons.queue_music_rounded, color: scheme.onSurfaceVariant), onPressed: tracks.isEmpty ? null : () => _menu(context, 'queue', album, tracks)),
                    const Spacer(),
                    if (tracks.isNotEmpty) ...[
                      IconButton(tooltip: 'Shuffle', iconSize: 28, icon: Icon(Icons.shuffle_rounded, color: scheme.primary), onPressed: () => s.player.playTracks(tracks, shuffle: true)),
                      const SizedBox(width: 6),
                      RoundIconButton(tooltip: 'Play', icon: Icons.play_arrow_rounded, size: 56, iconSize: 32, color: scheme.primary, iconColor: scheme.onPrimary, onPressed: () => s.player.playTracks(tracks)),
                    ],
                  ]),
                ]),
              ),
            ),
            SliverList.builder(
              itemCount: tracks.length,
              itemBuilder: (context, i) {
                final tr = tracks[i];
                final showDisc = discs.length > 1 && (i == 0 || (tracks[i - 1].discNo ?? 1) != (tr.discNo ?? 1));
                return Column(children: [
                  if (showDisc) Align(alignment: Alignment.centerLeft, child: Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: Eyebrow('Disc ${tr.discNo ?? 1}'))),
                  TrackTile(track: tr, showArt: false, leadingNumber: tr.trackNo ?? i + 1, subtitleOverride: tr.artistName != album.artistName ? tr.displayArtist : null, onTap: () => s.player.playTracks(tracks, index: i)),
                ]);
              },
            ),
            SliverToBoxAdapter(child: SizedBox(height: bottomClearance(context))),
          ]);
            },
          );
        },
      ),
    );
  }

  Future<void> _menu(BuildContext context, String v, Album album, List<Track> tracks) async {
    final s = context.read<AppServices>();
    switch (v) {
      case 'queue':
        await s.player.enqueue(tracks);
        if (context.mounted) showSnack(context, 'Added to queue');
      case 'playlist':
        await showAddToPlaylistSheet(context, tracks);
      case 'fix':
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => FixTagsScreen(initial: tracks)));
      case 'edit':
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AlbumEditorScreen(albumId: album.id)));
      case 'cover':
        await changeAlbumCover(context, album);
      case 'missing':
        await _missing(context, album, tracks);
    }
  }

  Future<void> _missing(BuildContext context, Album album, List<Track> tracks) async {
    final s = context.read<AppServices>();
    if (album.mbReleaseId == null) {
      showSnack(context, 'Identify the album first so its tracklist is known');
      return;
    }
    final detail = await s.identify.musicBrainz.release(album.mbReleaseId!);
    if (detail == null || !context.mounted) return;
    final have = {for (final t in tracks) if (t.mbRecordingId != null) t.mbRecordingId!};
    final haveTitles = {for (final t in tracks) normalizeName(t.title)};
    final missing = detail.tracks.where((t) => !have.contains(t.recordingId) && !haveTitles.contains(normalizeName(t.title))).toList();
    if (missing.isEmpty) {
      showSnack(context, 'You have every track of this release');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('${missing.length} missing'),
        content: SizedBox(width: 400, child: ListView(shrinkWrap: true, children: [for (final m in missing) ListTile(dense: true, title: Text(m.title), leading: Text('${m.number}'))])),
        actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Close')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Find & download'))],
      ),
    );
    if (ok != true) return;
    var queued = 0;
    for (final m in missing) {
      final w = WishTrack(artist: album.displayArtist, title: m.title, album: album.title, durationMs: m.lengthMs);
      final id = await s.wishlist.add(w, origin: 'album');
      if (await s.wishDownloader.download(id, w)) queued++;
    }
    if (context.mounted) showSnack(context, '$queued of ${missing.length} queued for download');
  }
}

/// Bottom-sheet flow to replace an album's cover (web search, gallery or automatic lookup).
Future<void> changeAlbumCover(BuildContext context, Album album) async {
  final s = context.read<AppServices>();
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (c) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(leading: const Icon(Icons.auto_awesome), title: const Text('Find automatically'), subtitle: const Text('Best match from the enabled cover providers'), onTap: () => Navigator.pop(c, 'auto')),
        ListTile(leading: const Icon(Icons.image_search), title: const Text('Search online'), subtitle: const Text('Pick from the candidates yourself'), onTap: () => Navigator.pop(c, 'search')),
        ListTile(leading: const Icon(Icons.photo_library_outlined), title: const Text('Choose from device'), onTap: () => Navigator.pop(c, 'file')),
      ]),
    ),
  );
  if (choice == null || !context.mounted) return;
  if (choice == 'auto') {
    showSnack(context, 'Looking for a cover…');
    File? f;
    try {
      f = await s.covers.ensureAlbumCover(album, force: true);
    } on Object {
      f = null;
    }
    LibraryEditor.evictImages();
    s.coverCache.retry(album.id);
    if (context.mounted) showSnack(context, f == null ? 'No cover found online' : 'Cover updated');
    return;
  }
  if (choice == 'file') {
    final r = await FilePicker.pickFile(type: FileType.image);
    if (r?.path == null) return;
    await s.covers.setManual(album, await File(r!.path!).readAsBytes());
    LibraryEditor.evictImages();
    s.coverCache.retry(album.id);
    if (context.mounted) showSnack(context, 'Cover updated');
    return;
  }
  final q = CoverQuery(artist: album.compilation ? null : album.artistName, album: album.title, mbReleaseId: album.mbReleaseId, mbReleaseGroupId: album.mbReleaseGroupId);
  if (!context.mounted) return;
  final picked = await showModalBottomSheet<CoverCandidate>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (c) => FutureBuilder<List<CoverCandidate>>(
      future: s.covers.searchCandidates(q),
      builder: (context, snap) {
        if (!snap.hasData) return const SizedBox(height: 200, child: Center(child: CircularProgressIndicator()));
        if (snap.data!.isEmpty) return const SizedBox(height: 200, child: EmptyState(icon: Icons.image_not_supported_outlined, title: 'No covers found'));
        return GridView.count(
          crossAxisCount: 3,
          padding: const EdgeInsets.all(12),
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          shrinkWrap: true,
          children: [
            for (final cand in snap.data!)
              InkWell(onTap: () => Navigator.pop(c, cand), child: Stack(fit: StackFit.expand, children: [
                Image.network(cand.url, fit: BoxFit.cover, errorBuilder: (_, _, _) => const ColoredBox(color: Colors.black12)),
                Positioned(left: 4, bottom: 4, child: Chip(label: Text(cand.source, style: const TextStyle(fontSize: 10)), visualDensity: VisualDensity.compact)),
              ])),
          ],
        );
      },
    ),
  );
  if (picked == null) return;
  final f = await s.covers.useCandidate(album, picked);
  if (f != null) {
    LibraryEditor.evictImages();
    s.coverCache.retry(album.id);
    if (context.mounted) showSnack(context, 'Cover updated');
  }
}
