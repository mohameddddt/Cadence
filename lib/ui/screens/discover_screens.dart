import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/app_services.dart';
import '../../core/models/library_models.dart';
import '../../features/integrations/metadata_clients.dart';
import '../../features/integrations/playlist_importer.dart';
import '../../features/sources/podcast_radio.dart';
import '../widgets/common.dart';
import '../widgets/cover_art.dart';
import 'search_screen.dart';

// ---------------------------------------------------------------------------
// Internet radio
// ---------------------------------------------------------------------------

class RadioScreen extends StatefulWidget {
  const RadioScreen({super.key});

  @override
  State<RadioScreen> createState() => _RadioScreenState();
}

class _RadioScreenState extends State<RadioScreen> {
  final _q = TextEditingController();
  Future<List<RadioStation>>? _results;
  String? _tag;

  static const _tags = ['jazz', 'rock', 'classical', 'electronic', 'pop', 'news', 'ambient', 'lofi', 'reggae', 'metal'];

  void _search() {
    final s = context.read<AppServices>();
    setState(() => _results = s.radioStations.search(name: _q.text.trim(), tag: _tag));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    return Scaffold(
      appBar: AppBar(title: const Text('Internet radio')),
      body: ListView(padding: const EdgeInsets.only(bottom: 120), children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(controller: _q, textInputAction: TextInputAction.search, onSubmitted: (_) => _search(), decoration: InputDecoration(border: const OutlineInputBorder(), hintText: 'Station name', suffixIcon: IconButton(icon: const Icon(Icons.search), onPressed: _search))),
        ),
        SizedBox(
          height: 44,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
            for (final t in _tags)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilterChip(label: Text(t), selected: _tag == t, onSelected: (v) {
                  setState(() => _tag = v ? t : null);
                  _search();
                }),
              ),
          ]),
        ),
        if (_results == null) ...[
          const SectionHeader('Favourites'),
          FutureBuilder<List<RadioStation>>(
            future: s.radioStations.favorites(),
            builder: (context, snap) => Column(children: [
              for (final st in snap.data ?? const <RadioStation>[]) _StationTile(station: st, onChanged: () => setState(() {})),
              if (snap.data != null && snap.data!.isEmpty) const ListTile(title: Text('Search a station and tap the heart to keep it here.')),
            ]),
          ),
        ] else
          FutureBuilder<List<RadioStation>>(
            future: _results,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) return const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()));
              if (snap.hasError) return Padding(padding: const EdgeInsets.all(16), child: Text('Search failed: ${snap.error}'));
              final list = snap.data ?? const [];
              if (list.isEmpty) return const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('No stations found')));
              return Column(children: [for (final st in list) _StationTile(station: st, onChanged: () => setState(() {}))]);
            },
          ),
      ]),
    );
  }
}

class _StationTile extends StatelessWidget {
  const _StationTile({required this.station, required this.onChanged});
  final RadioStation station;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    return FutureBuilder<bool>(
      future: s.radioStations.isFavorite(station.url),
      builder: (context, fav) {
        final isFav = fav.data ?? false;
        return ListTile(
          leading: CoverArt(url: station.favicon, seed: station.name, size: 44),
          title: Text(station.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text([if (station.country != null) station.country!, if (station.codec != null) station.codec!, if (station.bitrate != null && station.bitrate! > 0) '${station.bitrate} kbps'].join(' · ')),
          trailing: IconButton(
            tooltip: isFav ? 'Remove favourite' : 'Favourite',
            icon: Icon(isFav ? Icons.favorite : Icons.favorite_border),
            onPressed: () async {
              isFav ? await s.radioStations.removeFavorite(station.url) : await s.radioStations.addFavorite(station);
              onChanged();
            },
          ),
          onTap: () async {
            await s.player.playStation(station);
            s.radioStations.registerClick(station.uuid);
          },
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Podcasts
// ---------------------------------------------------------------------------

class PodcastsScreen extends StatefulWidget {
  const PodcastsScreen({super.key});

  @override
  State<PodcastsScreen> createState() => _PodcastsScreenState();
}

class _PodcastsScreenState extends State<PodcastsScreen> {
  final _q = TextEditingController();
  Future<List<PodcastFeed>>? _results;

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    return Scaffold(
      appBar: AppBar(title: const Text('Podcasts')),
      body: ListView(padding: const EdgeInsets.only(bottom: 120), children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: _q,
            textInputAction: TextInputAction.search,
            onSubmitted: (v) => setState(() => _results = s.podcasts.search(v.trim())),
            decoration: InputDecoration(border: const OutlineInputBorder(), hintText: 'Search podcasts or paste an RSS link', suffixIcon: IconButton(icon: const Icon(Icons.search), onPressed: () => setState(() => _results = s.podcasts.search(_q.text.trim())))),
          ),
        ),
        if (_results == null)
          StreamBuilder<List<PodcastFeed>>(
            stream: s.db.watch(s.podcasts.subscriptions),
            builder: (context, snap) {
              final subs = snap.data ?? const <PodcastFeed>[];
              if (subs.isEmpty) return const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('No subscriptions yet. Search above.')));
              return Column(children: [const SectionHeader('Subscriptions'), for (final f in subs) _feedTile(context, f)]);
            },
          )
        else
          FutureBuilder<List<PodcastFeed>>(
            future: _results,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) return const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()));
              if (snap.hasError) return Padding(padding: const EdgeInsets.all(16), child: Text('Search failed: ${snap.error}'));
              return Column(children: [for (final f in snap.data ?? const <PodcastFeed>[]) _feedTile(context, f)]);
            },
          ),
      ]),
    );
  }

  Widget _feedTile(BuildContext context, PodcastFeed f) => ListTile(
        leading: CoverArt(url: f.imageUrl, seed: f.title, size: 52),
        title: Text(f.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(f.author ?? ''),
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PodcastDetailScreen(feed: f))),
      );
}

class PodcastDetailScreen extends StatelessWidget {
  const PodcastDetailScreen({super.key, required this.feed});
  final PodcastFeed feed;

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    return Scaffold(
      appBar: AppBar(
        title: Text(feed.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          StreamBuilder<bool>(
            stream: s.db.watch(() => s.podcasts.isSubscribed(feed.feedUrl)),
            builder: (context, snap) {
              final sub = snap.data ?? false;
              return TextButton.icon(
                onPressed: () => sub ? s.podcasts.unsubscribe(feed.feedUrl) : s.podcasts.subscribe(feed),
                icon: Icon(sub ? Icons.check : Icons.add),
                label: Text(sub ? 'Subscribed' : 'Subscribe'),
              );
            },
          ),
        ],
      ),
      body: FutureBuilder(
        future: s.podcasts.fetch(feed.feedUrl),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          if (snap.hasError) return EmptyState(icon: Icons.error_outline, title: 'Could not load the feed', message: '${snap.error}');
          final eps = snap.data!.episodes;
          return ListView.builder(
            padding: const EdgeInsets.only(bottom: 120),
            itemCount: eps.length,
            itemBuilder: (context, i) {
              final e = eps[i];
              return ListTile(
                leading: CoverArt(url: e.imageUrl, seed: e.podcast, size: 48),
                title: Text(e.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text([if (e.published != null) '${e.published!.year}-${e.published!.month.toString().padLeft(2, '0')}-${e.published!.day.toString().padLeft(2, '0')}', if (e.duration != null) formatDuration(e.duration!)].join(' · ')),
                onTap: () => s.player.playEpisodes(eps, index: i),
                trailing: IconButton(tooltip: 'Download', icon: const Icon(Icons.download), onPressed: () => downloadRemote(context, e.toRemoteTrack())),
              );
            },
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Playlist import + wishlist
// ---------------------------------------------------------------------------

class PlaylistImportScreen extends StatefulWidget {
  const PlaylistImportScreen({super.key});

  @override
  State<PlaylistImportScreen> createState() => _PlaylistImportScreenState();
}

class _PlaylistImportScreenState extends State<PlaylistImportScreen> {
  final _url = TextEditingController();
  ImportPlan? _plan;
  bool _busy = false;
  String? _error;

  Future<void> _fetch() async {
    final s = context.read<AppServices>();
    setState(() {
      _busy = true;
      _error = null;
      _plan = null;
    });
    try {
      final p = await s.importer.fetch(_url.text.trim());
      final plan = await s.importer.plan(p);
      if (mounted) setState(() => _plan = plan);
    } on Object catch (e) {
      if (mounted) setState(() => _error = e is StateError ? e.message : '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    final plan = _plan;
    return Scaffold(
      appBar: AppBar(title: const Text('Import playlist')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('Paste a Spotify, Deezer or YouTube playlist link. Songs you already own become a playlist; the rest go to your wishlist so you can find them on other sources.'),
        const SizedBox(height: 12),
        TextField(controller: _url, decoration: InputDecoration(border: const OutlineInputBorder(), hintText: 'https://open.spotify.com/playlist/…', suffixIcon: IconButton(icon: const Icon(Icons.download), onPressed: _fetch))),
        if (_busy) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
        if (plan != null) ...[
          const SizedBox(height: 16),
          Text(plan.playlist.name, style: Theme.of(context).textTheme.titleLarge),
          Text('${plan.playlist.tracks.length} songs · ${plan.matched.length} in your library · ${plan.missing.length} missing'),
          const SizedBox(height: 12),
          FilledButton.icon(
            icon: const Icon(Icons.playlist_add_check),
            label: const Text('Create playlist & wishlist missing'),
            onPressed: () async {
              await s.importer.commit(plan);
              if (context.mounted) {
                showSnack(context, 'Playlist created; ${plan.missing.length} songs added to the wishlist');
                Navigator.pop(context);
              }
            },
          ),
          const SectionHeader('Missing'),
          for (final m in plan.missing) ListTile(dense: true, title: Text(m.title), subtitle: Text(m.artist)),
        ],
      ]),
    );
  }
}

class WishlistScreen extends StatelessWidget {
  const WishlistScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Wishlist'),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.download),
            label: const Text('Find all'),
            onPressed: () async {
              var n = 0;
              for (final w in await s.wishlist.all(status: 'pending')) {
                if (await s.wishDownloader.download(w.id, WishTrack(artist: w.artist, title: w.title, album: w.album))) n++;
              }
              if (context.mounted) showSnack(context, '$n downloads queued');
            },
          ),
        ],
      ),
      body: StreamBuilder<List<WishlistItem>>(
        stream: s.wishlist.watch(),
        builder: (context, snap) {
          final items = snap.data;
          if (items == null) return const Center(child: CircularProgressIndicator());
          if (items.isEmpty) return const EmptyState(icon: Icons.bookmark_border, title: 'Wishlist is empty', message: 'Songs you want but do not have show up here (imported playlists, radio suggestions).');
          return ListView.builder(
            itemCount: items.length,
            itemBuilder: (context, i) {
              final w = items[i];
              return ListTile(
                title: Text(w.title),
                subtitle: Text('${w.artist}${w.album == null ? '' : ' · ${w.album}'} · ${w.status}'),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(tooltip: 'Find & download', icon: const Icon(Icons.download), onPressed: () async {
                    final ok = await s.wishDownloader.download(w.id, WishTrack(artist: w.artist, title: w.title, album: w.album));
                    if (context.mounted) showSnack(context, ok ? 'Download queued' : 'No good match found');
                  }),
                  IconButton(tooltip: 'Remove', icon: const Icon(Icons.close), onPressed: () => s.wishlist.remove(w.id)),
                ]),
              );
            },
          );
        },
      ),
    );
  }
}
