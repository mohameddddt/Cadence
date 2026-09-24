import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/app_services.dart';
import '../../core/library/smart_rules.dart';
import '../../core/models/library_models.dart';
import '../../core/models/track.dart';
import '../widgets/common.dart';
import '../widgets/cover_art.dart';
import '../widgets/track_widgets.dart';
import 'album_screen.dart';
import 'artist_screen.dart';
import 'playlist_screens.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 6, vsync: this);
  TrackSort _sort = TrackSort.title;
  bool _desc = false;
  String _filter = '';
  bool _showFilter = false;

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppServices>().settings;
    return Scaffold(
      appBar: AppBar(
        title: _showFilter
            ? TextField(autofocus: true, decoration: const InputDecoration(hintText: 'Filter…', border: InputBorder.none), onChanged: (v) => setState(() => _filter = v.trim()))
            : const Text('Library'),
        actions: [
          IconButton(tooltip: 'Filter', icon: Icon(_showFilter ? Icons.close : Icons.filter_list), onPressed: () => setState(() {
                _showFilter = !_showFilter;
                if (!_showFilter) _filter = '';
              })),
          IconButton(tooltip: s.libraryGrid ? 'List view' : 'Grid view', icon: Icon(s.libraryGrid ? Icons.view_list : Icons.grid_view), onPressed: () => s.setLibraryGrid(!s.libraryGrid)),
          PopupMenuButton<TrackSort>(
            tooltip: 'Sort',
            icon: const Icon(Icons.sort),
            onSelected: (v) => setState(() {
              if (_sort == v) {
                _desc = !_desc;
              } else {
                _sort = v;
                _desc = v == TrackSort.dateAdded || v == TrackSort.playCount || v == TrackSort.lastPlayed;
              }
            }),
            itemBuilder: (_) => [
              for (final o in const [TrackSort.title, TrackSort.artist, TrackSort.album, TrackSort.dateAdded, TrackSort.playCount, TrackSort.duration, TrackSort.year])
                CheckedPopupMenuItem(value: o, checked: _sort == o, child: Text(_sortLabel(o))),
            ],
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: const [Tab(text: 'Songs'), Tab(text: 'Albums'), Tab(text: 'Artists'), Tab(text: 'Genres'), Tab(text: 'Folders'), Tab(text: 'Playlists')],
        ),
      ),
      body: TabBarView(controller: _tabs, children: [
        _SongsTab(sort: _sort, desc: _desc, filter: _filter),
        _AlbumsTab(filter: _filter, grid: s.libraryGrid),
        _ArtistsTab(filter: _filter),
        _GenresTab(filter: _filter),
        _FoldersTab(filter: _filter),
        const PlaylistsTab(),
      ]),
    );
  }

  String _sortLabel(TrackSort o) => switch (o) {
        TrackSort.title => 'Title',
        TrackSort.artist => 'Artist',
        TrackSort.album => 'Album',
        TrackSort.dateAdded => 'Date added',
        TrackSort.playCount => 'Most played',
        TrackSort.duration => 'Duration',
        TrackSort.year => 'Year',
        _ => o.name,
      };
}

class _SongsTab extends StatelessWidget {
  const _SongsTab({required this.sort, required this.desc, required this.filter});
  final TrackSort sort;
  final bool desc;
  final String filter;

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    return StreamBuilder<List<Track>>(
      key: ValueKey('$sort$desc$filter'),
      stream: s.db.watch(() => filter.isEmpty ? s.repo.tracks(sort: sort, descending: desc) : s.repo.searchTracks(filter, limit: 500)),
      builder: (context, snap) {
        final tracks = snap.data;
        if (tracks == null) return const Center(child: CircularProgressIndicator());
        if (tracks.isEmpty) return _empty(context, s, filter.isNotEmpty);
        return Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
            child: Row(children: [
              Text('${tracks.length} songs', style: Theme.of(context).textTheme.labelLarge),
              const Spacer(),
              TextButton.icon(onPressed: () => s.player.playTracks(tracks, shuffle: true), icon: const Icon(Icons.shuffle, size: 18), label: const Text('Shuffle all')),
            ]),
          ),
          Expanded(child: TrackListView(tracks: tracks, padding: const EdgeInsets.only(bottom: 120))),
        ]);
      },
    );
  }
}

Widget _empty(BuildContext context, AppServices s, bool filtered) => EmptyState(
      icon: filtered ? Icons.search_off : Icons.library_music_outlined,
      title: filtered ? 'Nothing matches' : 'Your library is empty',
      message: filtered ? null : 'Scan this device for music, or download something from the Search tab.',
      action: filtered ? null : FilledButton.icon(onPressed: () => s.scanner.scan(force: true), icon: const Icon(Icons.refresh), label: const Text('Scan now')),
    );

class _AlbumsTab extends StatelessWidget {
  const _AlbumsTab({required this.filter, required this.grid});
  final String filter;
  final bool grid;

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    return StreamBuilder<List<Album>>(
      key: ValueKey(filter),
      stream: s.db.watch(() => s.repo.albums(query: filter)),
      builder: (context, snap) {
        final albums = snap.data;
        if (albums == null) return const Center(child: CircularProgressIndicator());
        if (albums.isEmpty) return _empty(context, s, filter.isNotEmpty);
        if (!grid) {
          return ListView.builder(
            padding: const EdgeInsets.only(bottom: 120),
            itemCount: albums.length,
            itemBuilder: (context, i) => ListTile(
              leading: CoverArt(albumId: albums[i].id, seed: albums[i].title, size: 52),
              title: Text(albums[i].title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('${albums[i].displayArtist} · ${albums[i].trackCount} songs'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AlbumScreen(albumId: albums[i].id))),
            ),
          );
        }
        final w = MediaQuery.sizeOf(context).width;
        final cols = (w / 170).floor().clamp(2, 6);
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: cols, mainAxisSpacing: 16, crossAxisSpacing: 12, childAspectRatio: 0.78),
          itemCount: albums.length,
          itemBuilder: (context, i) => AlbumCard(album: albums[i]),
        );
      },
    );
  }
}

class _ArtistsTab extends StatelessWidget {
  const _ArtistsTab({required this.filter});
  final String filter;

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    return StreamBuilder<List<Artist>>(
      key: ValueKey(filter),
      stream: s.db.watch(() => s.repo.artists(query: filter)),
      builder: (context, snap) {
        final artists = snap.data;
        if (artists == null) return const Center(child: CircularProgressIndicator());
        if (artists.isEmpty) return _empty(context, s, filter.isNotEmpty);
        return ListView.builder(
          padding: const EdgeInsets.only(bottom: 120),
          itemCount: artists.length,
          itemBuilder: (context, i) => ListTile(
            leading: CoverArt(artistId: artists[i].id, seed: artists[i].name, size: 52, circle: true),
            title: Text(artists[i].name),
            subtitle: Text('${artists[i].albumCount} albums · ${artists[i].trackCount} songs'),
            trailing: artists[i].followed ? const Icon(Icons.notifications_active, size: 18) : null,
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ArtistScreen(artistId: artists[i].id))),
          ),
        );
      },
    );
  }
}

class _GenresTab extends StatelessWidget {
  const _GenresTab({required this.filter});
  final String filter;

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    return StreamBuilder<List<({String name, int count})>>(
      stream: s.db.watch(s.repo.genres),
      builder: (context, snap) {
        final all = snap.data;
        if (all == null) return const Center(child: CircularProgressIndicator());
        final genres = all.where((g) => filter.isEmpty || g.name.toLowerCase().contains(filter.toLowerCase())).toList();
        if (genres.isEmpty) return _empty(context, s, filter.isNotEmpty);
        return ListView.builder(
          padding: const EdgeInsets.only(bottom: 120),
          itemCount: genres.length,
          itemBuilder: (context, i) => ListTile(
            leading: CircleAvatar(child: Text(initialsOf(genres[i].name))),
            title: Text(genres[i].name),
            subtitle: Text('${genres[i].count} songs'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => TrackCollectionScreen(title: genres[i].name, loader: () => s.repo.tracks(genre: genres[i].name)))),
          ),
        );
      },
    );
  }
}

class _FoldersTab extends StatelessWidget {
  const _FoldersTab({required this.filter});
  final String filter;

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    return StreamBuilder<List<({String path, int count})>>(
      stream: s.db.watch(s.repo.folders),
      builder: (context, snap) {
        final all = snap.data;
        if (all == null) return const Center(child: CircularProgressIndicator());
        final folders = all.where((f) => filter.isEmpty || f.path.toLowerCase().contains(filter.toLowerCase())).toList();
        if (folders.isEmpty) return _empty(context, s, filter.isNotEmpty);
        return ListView.builder(
          padding: const EdgeInsets.only(bottom: 120),
          itemCount: folders.length,
          itemBuilder: (context, i) {
            final name = folders[i].path.split('/').where((e) => e.isNotEmpty).lastOrNull ?? folders[i].path;
            return ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: Text(name),
              subtitle: Text('${folders[i].path} · ${folders[i].count} songs', maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => TrackCollectionScreen(title: name, loader: () => s.repo.tracks(folder: folders[i].path)))),
            );
          },
        );
      },
    );
  }
}

/// Generic "list of tracks" page (genre, folder, most played...).
class TrackCollectionScreen extends StatelessWidget {
  const TrackCollectionScreen({super.key, required this.title, required this.loader});
  final String title;
  final Future<List<Track>> Function() loader;

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: StreamBuilder<List<Track>>(
        stream: s.db.watch(loader),
        builder: (context, snap) {
          final tracks = snap.data;
          if (tracks == null) return const Center(child: CircularProgressIndicator());
          if (tracks.isEmpty) return const EmptyState(icon: Icons.music_off, title: 'No songs');
          return Column(children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(children: [
                FilledButton.icon(onPressed: () => s.player.playTracks(tracks), icon: const Icon(Icons.play_arrow), label: const Text('Play')),
                const SizedBox(width: 8),
                OutlinedButton.icon(onPressed: () => s.player.playTracks(tracks, shuffle: true), icon: const Icon(Icons.shuffle), label: const Text('Shuffle')),
              ]),
            ),
            Expanded(child: TrackListView(tracks: tracks, padding: const EdgeInsets.only(bottom: 120))),
          ]);
        },
      ),
    );
  }
}
