import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/app_services.dart';
import '../../core/library/smart_rules.dart';
import '../../core/models/library_models.dart';
import '../../core/models/track.dart';
import '../widgets/common.dart';
import '../widgets/cover_tint.dart';
import '../widgets/kit.dart';
import '../widgets/track_widgets.dart';
import 'playlist_editor.dart';

class PlaylistsTab extends StatelessWidget {
  const PlaylistsTab({super.key, this.grid = false, this.filter = ''});

  final bool grid;
  final String filter;

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    final scheme = Theme.of(context).colorScheme;
    return StreamBuilder<({List<Playlist> lists, int loved})>(
      stream: s.db.watch(() async => (lists: await s.repo.playlists(), loved: (await s.repo.lovedTracks()).length)),
      builder: (context, snap) {
        final d = snap.data;
        if (d == null) return const Loader();
        final f = filter.toLowerCase();
        final lists = f.isEmpty ? d.lists : d.lists.where((p) => p.name.toLowerCase().contains(f)).toList();
        final pinned = <_Pinned>[
          _Pinned('Liked songs', 'Playlist · ${d.loved} song${d.loved == 1 ? '' : 's'}', Icons.favorite_rounded, [scheme.primary, Color.lerp(scheme.primary, Colors.white, 0.55)!],
              () => _open(context, 'Liked songs', s.repo.lovedTracks)),
          _Pinned('Recently played', 'Your last 100 songs', Icons.history_rounded, [const Color(0xFF3B5BDB), const Color(0xFF91A7FF)],
              () => _open(context, 'Recently played', () => s.repo.recentlyPlayed(limit: 100))),
          _Pinned('On repeat', 'Your most played', Icons.trending_up_rounded, [const Color(0xFFE8590C), const Color(0xFFFFC078)],
              () => _open(context, 'On repeat', () => s.repo.mostPlayed(limit: 100))),
        ].where((p) => f.isEmpty || p.title.toLowerCase().contains(f)).toList();

        if (grid) {
          return GridView.builder(
            padding: EdgeInsets.fromLTRB(16, 8, 16, bottomClearance(context)),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 180, mainAxisSpacing: 16, crossAxisSpacing: 14, childAspectRatio: 0.76),
            itemCount: pinned.length + lists.length,
            itemBuilder: (context, i) => i < pinned.length ? _PinnedCard(pinned[i]) : _PlaylistCard(playlist: lists[i - pinned.length]),
          );
        }
        return ListView(padding: EdgeInsets.only(top: 4, bottom: bottomClearance(context)), children: [
          for (final p in pinned)
            _Row(
              art: _GradientArt(p.icon, p.colors),
              title: p.title,
              subtitle: p.subtitle,
              pinned: true,
              onTap: p.onTap,
            ),
          for (final p in lists)
            _Row(
              art: PlaylistCover(playlist: p, size: 64, radius: 4),
              title: p.name,
              subtitle: p.isSmart ? 'Smart playlist' : 'Playlist · ${p.trackCount} song${p.trackCount == 1 ? '' : 's'}',
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PlaylistScreen(playlistId: p.id))),
              onLongPress: p.isSmart ? null : () => showPlaylistEditor(context, existing: p),
            ),
          _Row(
            art: Container(width: 64, height: 64, decoration: BoxDecoration(color: scheme.surfaceContainerHigh, shape: BoxShape.circle), child: Icon(Icons.add_rounded, size: 32, color: scheme.onSurfaceVariant)),
            title: 'Create playlist',
            subtitle: 'Name it and add a picture',
            onTap: () => _openNew(context),
          ),
          _Row(
            art: Container(width: 64, height: 64, decoration: BoxDecoration(color: scheme.surfaceContainerHigh, shape: BoxShape.circle), child: Icon(Icons.auto_awesome_rounded, size: 26, color: scheme.onSurfaceVariant)),
            title: 'Smart playlist',
            subtitle: 'Fills itself from rules',
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SmartPlaylistEditor())),
          ),
        ]);
      },
    );
  }

  Future<void> _openNew(BuildContext context) async {
    final id = await showPlaylistEditor(context);
    if (id != null && context.mounted) Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PlaylistScreen(playlistId: id)));
  }

  static void _open(BuildContext context, String title, Future<List<Track>> Function() loader) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _SimpleTracks(title: title, loader: loader)));
  }
}

class _Pinned {
  const _Pinned(this.title, this.subtitle, this.icon, this.colors, this.onTap);
  final String title;
  final String subtitle;
  final IconData icon;
  final List<Color> colors;
  final VoidCallback onTap;
}

class _GradientArt extends StatelessWidget {
  const _GradientArt(this.icon, this.colors, {this.size = 64});
  final IconData icon;
  final List<Color> colors;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors)),
        child: Icon(icon, color: Colors.white, size: size * 0.4),
      );
}

/// A library row: 64px art, title, and a subtitle with a pin for the built-in lists.
class _Row extends StatelessWidget {
  const _Row({required this.art, required this.title, required this.subtitle, required this.onTap, this.onLongPress, this.pinned = false});

  final Widget art;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool pinned;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        child: Row(children: [
          art,
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.titleMedium),
              const SizedBox(height: 2),
              Row(children: [
                if (pinned) ...[Transform.rotate(angle: 0.7, child: Icon(Icons.push_pin_rounded, size: 13, color: t.colorScheme.primary)), const SizedBox(width: 5)],
                Flexible(child: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant))),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _PinnedCard extends StatelessWidget {
  const _PinnedCard(this.p);
  final _Pinned p;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: p.onTap,
      child: LayoutBuilder(builder: (context, c) {
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _GradientArt(p.icon, p.colors, size: c.maxWidth),
          const SizedBox(height: 8),
          Text(p.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
          Text(p.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ]);
      }),
    );
  }
}

class _PlaylistCard extends StatelessWidget {
  const _PlaylistCard({required this.playlist});
  final Playlist playlist;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final p = playlist;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PlaylistScreen(playlistId: p.id))),
      onLongPress: p.isSmart ? null : () => showPlaylistEditor(context, existing: p),
      child: LayoutBuilder(builder: (context, c) {
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          PlaylistCover(playlist: p, size: c.maxWidth, radius: 4),
          const SizedBox(height: 8),
          Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
          Text(p.isSmart ? 'Smart playlist' : '${p.trackCount} song${p.trackCount == 1 ? '' : 's'}', maxLines: 1, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ]);
      }),
    );
  }
}

class _SimpleTracks extends StatelessWidget {
  const _SimpleTracks({required this.title, required this.loader});
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
          final t = snap.data;
          if (t == null) return const Loader();
          if (t.isEmpty) return const EmptyState(icon: Icons.music_off_rounded, title: 'Nothing here yet');
          return TrackListView(tracks: t, padding: EdgeInsets.only(bottom: bottomClearance(context)));
        },
      ),
    );
  }
}

class PlaylistScreen extends StatelessWidget {
  const PlaylistScreen({super.key, required this.playlistId});
  final int playlistId;

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    return StreamBuilder<({Playlist? p, List<({int entryId, Track track})> entries})>(
      stream: s.db.watch(() async {
        final p = await s.repo.playlistById(playlistId);
        if (p == null) return (p: null, entries: <({int entryId, Track track})>[]);
        if (p.isSmart) {
          final tracks = await s.repo.playlistTracks(p);
          return (p: p, entries: [for (final t in tracks) (entryId: 0, track: t)]);
        }
        return (p: p, entries: await s.repo.playlistEntries(playlistId));
      }),
      builder: (context, snap) {
        final d = snap.data;
        if (d == null) return const Scaffold(body: Loader());
        final p = d.p;
        if (p == null) return Scaffold(appBar: AppBar(), body: const EmptyState(icon: Icons.queue_music_rounded, title: 'Playlist not found'));
        final tracks = [for (final e in d.entries) e.track];
        final t = Theme.of(context);
        final scheme = t.colorScheme;
        final total = tracks.fold<int>(0, (a, b) => a + b.durationMs);
        final tintPath = p.coverPath ?? (tracks.isEmpty ? null : s.coverCache.albumCover(tracks.first.albumId));

        Future<void> menu(String v) async {
          if (v == 'edit') {
            await showPlaylistEditor(context, existing: p);
          } else if (v == 'rename') {
            final n = await promptText(context, title: 'Rename', initial: p.name);
            if (n != null) await s.repo.renamePlaylist(p.id, n);
          } else if (v == 'rules') {
            await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SmartPlaylistEditor(existing: p)));
          } else if (v == 'delete') {
            await s.repo.deletePlaylist(p.id);
            await deletePlaylistCoverFile(p.coverPath);
            if (context.mounted) Navigator.pop(context);
          } else if (v == 'queue') {
            await s.player.enqueue(tracks);
            if (context.mounted) showSnack(context, 'Added to queue');
          }
        }

        final header = CoverTintBuilder(
          path: tintPath,
          builder: (context, tint) {
            final top = tint == null ? scheme.surfaceContainerHighest : CoverTint.shade(tint, t.brightness == Brightness.dark ? 0.32 : 0.78);
            return AnimatedContainer(
              duration: const Duration(milliseconds: 400),
              decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [top, scheme.surface])),
              padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + kToolbarHeight, 16, 4),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Center(
                  child: GestureDetector(
                    onTap: p.isSmart ? null : () => showPlaylistEditor(context, existing: p),
                    child: PlaylistCover(playlist: p, size: 224, radius: 4),
                  ),
                ),
                const SizedBox(height: 20),
                Text(p.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.textTheme.headlineLarge),
                const SizedBox(height: 6),
                Text(
                  '${p.isSmart ? 'Smart playlist' : 'Playlist'} · ${tracks.length} song${tracks.length == 1 ? '' : 's'}${total > 0 ? ' · ${formatMs(total)}' : ''}',
                  style: t.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 6),
                Row(children: [
                  if (!p.isSmart) IconButton(tooltip: 'Edit name & picture', icon: Icon(Icons.edit_outlined, color: scheme.onSurfaceVariant), onPressed: () => menu('edit')),
                  if (p.isSmart) IconButton(tooltip: 'Edit rules', icon: Icon(Icons.tune_rounded, color: scheme.onSurfaceVariant), onPressed: () => menu('rules')),
                  IconButton(tooltip: 'Add to queue', icon: Icon(Icons.queue_music_rounded, color: scheme.onSurfaceVariant), onPressed: tracks.isEmpty ? null : () => menu('queue')),
                  PopupMenuButton<String>(
                    icon: Icon(Icons.more_horiz_rounded, color: scheme.onSurfaceVariant),
                    onSelected: menu,
                    itemBuilder: (_) => [
                      if (p.isSmart) const PopupMenuItem(value: 'rename', child: Text('Rename')),
                      const PopupMenuItem(value: 'delete', child: Text('Delete playlist')),
                    ],
                  ),
                  const Spacer(),
                  if (tracks.isNotEmpty) ...[
                    IconButton(tooltip: 'Shuffle', iconSize: 28, icon: Icon(Icons.shuffle_rounded, color: scheme.primary), onPressed: () => s.player.playTracks(tracks, shuffle: true)),
                    const SizedBox(width: 6),
                    RoundIconButton(tooltip: 'Play', icon: Icons.play_arrow_rounded, size: 56, iconSize: 32, color: scheme.primary, iconColor: scheme.onPrimary, onPressed: () => s.player.playTracks(tracks)),
                  ],
                ]),
              ]),
            );
          },
        );

        return Scaffold(
          extendBodyBehindAppBar: true,
          appBar: AppBar(backgroundColor: Colors.transparent),
          body: CustomScrollView(slivers: [
            SliverToBoxAdapter(child: header),
            if (tracks.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyState(icon: Icons.queue_music_rounded, title: 'Empty playlist', message: p.isSmart ? 'No songs match the rules yet.' : 'Add songs from the ⋮ menu of any track.'),
              )
            else if (p.isSmart)
              SliverList.builder(
                itemCount: tracks.length,
                itemBuilder: (context, i) => TrackTile(track: tracks[i], onTap: () => s.player.playTracks(tracks, index: i)),
              )
            else
              SliverReorderableList(
                itemCount: d.entries.length,
                onReorderItem: (o, n) => s.repo.reorderPlaylist(p.id, o, n),
                proxyDecorator: (child, _, _) => Material(color: scheme.surfaceContainerHigh, elevation: 6, child: child),
                itemBuilder: (context, i) {
                  final e = d.entries[i];
                  return TrackTile(
                    key: ValueKey('e${e.entryId}'),
                    track: e.track,
                    playlistId: p.id,
                    playlistEntryId: e.entryId,
                    onTap: () => s.player.playTracks(tracks, index: i),
                    trailing: ReorderableDragStartListener(index: i, child: Icon(Icons.drag_handle_rounded, color: scheme.onSurfaceVariant)),
                  );
                },
              ),
            SliverToBoxAdapter(child: SizedBox(height: bottomClearance(context))),
          ]),
        );
      },
    );
  }
}

/// Rule builder for smart playlists.
class SmartPlaylistEditor extends StatefulWidget {
  const SmartPlaylistEditor({super.key, this.existing});
  final Playlist? existing;

  @override
  State<SmartPlaylistEditor> createState() => _SmartPlaylistEditorState();
}

class _SmartPlaylistEditorState extends State<SmartPlaylistEditor> {
  late final TextEditingController _name = TextEditingController(text: widget.existing?.name ?? '');
  late final SmartRules _rules = SmartRules.parse(widget.existing?.smartRules);
  late List<SmartCondition> _conditions = List.of(_rules.conditions);
  bool _all = true;
  TrackSort _sort = TrackSort.title;
  bool _desc = false;
  int? _limit;
  int _preview = 0;

  @override
  void initState() {
    super.initState();
    _all = _rules.matchAll;
    _sort = _rules.sort;
    _desc = _rules.descending;
    _limit = _rules.limit;
    _refreshPreview();
  }

  SmartRules get _current => SmartRules(matchAll: _all, conditions: _conditions, sort: _sort, descending: _desc, limit: _limit);

  Future<void> _refreshPreview() async {
    final s = context.read<AppServices>();
    final q = _current.toQuery(nowSeconds: DateTime.now().millisecondsSinceEpoch ~/ 1000);
    final rows = await s.repo.db.rawQuery(q.sql, q.args);
    if (mounted) setState(() => _preview = rows.length);
  }

  Future<void> _save() async {
    final s = context.read<AppServices>();
    final name = _name.text.trim().isEmpty ? 'Smart playlist' : _name.text.trim();
    if (widget.existing == null) {
      await s.repo.createPlaylist(name, smart: _current);
    } else {
      await s.repo.renamePlaylist(widget.existing!.id, name);
      await s.repo.updateSmartRules(widget.existing!.id, _current);
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.existing == null ? 'New smart playlist' : 'Edit smart playlist'), actions: [TextButton(onPressed: _save, child: const Text('Save'))]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder())),
        const SizedBox(height: 16),
        Wrap(spacing: 8, children: [
          for (final e in SmartRules.presets.entries)
            ActionChip(label: Text(e.key), onPressed: () {
              setState(() {
                _conditions = List.of(e.value.conditions);
                _sort = e.value.sort;
                _desc = e.value.descending;
                _limit = e.value.limit;
                _all = e.value.matchAll;
                if (_name.text.isEmpty) _name.text = e.key;
              });
              _refreshPreview();
            }),
        ]),
        const SizedBox(height: 16),
        SegmentedButton<bool>(segments: const [ButtonSegment(value: true, label: Text('Match all')), ButtonSegment(value: false, label: Text('Match any'))], selected: {_all}, onSelectionChanged: (v) {
          setState(() => _all = v.first);
          _refreshPreview();
        }),
        const SizedBox(height: 8),
        for (var i = 0; i < _conditions.length; i++) _conditionRow(i),
        TextButton.icon(onPressed: () {
          setState(() => _conditions.add(const SmartCondition(SmartField.genre, SmartOp.contains, '')));
          _refreshPreview();
        }, icon: const Icon(Icons.add), label: const Text('Add rule')),
        const Divider(),
        Row(children: [
          Expanded(
            child: DropdownButtonFormField<TrackSort>(
              initialValue: _sort,
              decoration: const InputDecoration(labelText: 'Sort by'),
              items: [for (final o in TrackSort.values) DropdownMenuItem(value: o, child: Text(o.name))],
              onChanged: (v) {
                setState(() => _sort = v ?? _sort);
                _refreshPreview();
              },
            ),
          ),
          const SizedBox(width: 12),
          FilterChip(label: const Text('Descending'), selected: _desc, onSelected: (v) {
            setState(() => _desc = v);
            _refreshPreview();
          }),
        ]),
        const SizedBox(height: 12),
        DropdownButtonFormField<int?>(
          initialValue: _limit,
          decoration: const InputDecoration(labelText: 'Limit'),
          items: const [DropdownMenuItem(value: null, child: Text('No limit')), DropdownMenuItem(value: 25, child: Text('25 songs')), DropdownMenuItem(value: 50, child: Text('50 songs')), DropdownMenuItem(value: 100, child: Text('100 songs')), DropdownMenuItem(value: 250, child: Text('250 songs'))],
          onChanged: (v) {
            setState(() => _limit = v);
            _refreshPreview();
          },
        ),
        const SizedBox(height: 16),
        Text('Currently matches $_preview songs', style: t.textTheme.titleSmall),
      ]),
    );
  }

  Widget _conditionRow(int i) {
    final c = _conditions[i];
    final valueCtl = TextEditingController(text: c.value)..selection = TextSelection.collapsed(offset: c.value.length);
    List<SmartOp> ops() => switch (c.field) {
          final f when f.isText => const [SmartOp.contains, SmartOp.notContains, SmartOp.equals, SmartOp.notEquals, SmartOp.startsWith],
          final f when f.isNumber => const [SmartOp.equals, SmartOp.greaterThan, SmartOp.lessThan, SmartOp.notEquals],
          final f when f.isDate => const [SmartOp.withinDays, SmartOp.notWithinDays],
          _ => const [SmartOp.isTrue, SmartOp.isFalse],
        };
    final validOps = ops();
    final op = validOps.contains(c.op) ? c.op : validOps.first;
    final needsValue = !c.field.isFlag;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(children: [
          Expanded(
            flex: 3,
            child: DropdownButton<SmartField>(
              isExpanded: true,
              value: c.field,
              items: [for (final f in SmartField.values) DropdownMenuItem(value: f, child: Text(f.name))],
              onChanged: (v) {
                setState(() => _conditions[i] = SmartCondition(v!, SmartOp.contains, ''));
                setState(() {
                  final f = _conditions[i].field;
                  final first = (f.isText ? SmartOp.contains : f.isNumber ? SmartOp.equals : f.isDate ? SmartOp.withinDays : SmartOp.isTrue);
                  _conditions[i] = SmartCondition(f, first, '');
                });
                _refreshPreview();
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: DropdownButton<SmartOp>(
              isExpanded: true,
              value: op,
              items: [for (final o in validOps) DropdownMenuItem(value: o, child: Text(_opLabel(o)))],
              onChanged: (v) {
                setState(() => _conditions[i] = SmartCondition(c.field, v!, c.value));
                _refreshPreview();
              },
            ),
          ),
          const SizedBox(width: 8),
          if (needsValue)
            Expanded(
              flex: 3,
              child: TextField(
                controller: valueCtl,
                keyboardType: c.field.isText ? TextInputType.text : TextInputType.number,
                decoration: InputDecoration(hintText: c.field.isDate ? 'days' : 'value', isDense: true),
                onChanged: (v) {
                  _conditions[i] = SmartCondition(c.field, op, v);
                  _refreshPreview();
                },
              ),
            ),
          IconButton(icon: const Icon(Icons.close), onPressed: () {
            setState(() => _conditions.removeAt(i));
            _refreshPreview();
          }),
        ]),
      ),
    );
  }

  String _opLabel(SmartOp o) => switch (o) {
        SmartOp.contains => 'contains',
        SmartOp.notContains => "doesn't contain",
        SmartOp.equals => 'is',
        SmartOp.notEquals => 'is not',
        SmartOp.startsWith => 'starts with',
        SmartOp.greaterThan => 'is more than',
        SmartOp.lessThan => 'is less than',
        SmartOp.withinDays => 'within last (days)',
        SmartOp.notWithinDays => 'not within (days)',
        SmartOp.isTrue => 'is yes',
        SmartOp.isFalse => 'is no',
      };
}
