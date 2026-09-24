import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/app_services.dart';
import '../../core/library/smart_rules.dart';
import '../../core/models/library_models.dart';
import '../../core/models/track.dart';
import '../widgets/common.dart';
import '../widgets/track_widgets.dart';

class PlaylistsTab extends StatelessWidget {
  const PlaylistsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _create(context),
        icon: const Icon(Icons.add),
        label: const Text('New playlist'),
      ),
      body: StreamBuilder<List<Playlist>>(
        stream: s.db.watch(s.repo.playlists),
        builder: (context, snap) {
          final lists = snap.data;
          if (lists == null) return const Center(child: CircularProgressIndicator());
          return ListView(padding: const EdgeInsets.only(bottom: 160), children: [
            ListTile(leading: const CircleAvatar(child: Icon(Icons.favorite)), title: const Text('Favourites'), onTap: () => _open(context, 'Favourites', s.repo.lovedTracks)),
            ListTile(leading: const CircleAvatar(child: Icon(Icons.history)), title: const Text('Recently played'), onTap: () => _open(context, 'Recently played', () => s.repo.recentlyPlayed(limit: 100))),
            ListTile(leading: const CircleAvatar(child: Icon(Icons.trending_up)), title: const Text('Most played'), onTap: () => _open(context, 'Most played', () => s.repo.mostPlayed(limit: 100))),
            const Divider(),
            if (lists.isEmpty) const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('No playlists yet'))),
            for (final p in lists)
              ListTile(
                leading: CircleAvatar(child: Icon(p.isSmart ? Icons.auto_awesome : Icons.queue_music)),
                title: Text(p.name),
                subtitle: Text(p.isSmart ? 'Smart playlist' : '${p.trackCount} songs'),
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PlaylistScreen(playlistId: p.id))),
              ),
          ]);
        },
      ),
    );
  }

  void _open(BuildContext context, String title, Future<List<Track>> Function() loader) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _SimpleTracks(title: title, loader: loader)));
  }

  Future<void> _create(BuildContext context) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.queue_music), title: const Text('Playlist'), subtitle: const Text('Pick songs yourself'), onTap: () => Navigator.pop(c, 'manual')),
          ListTile(leading: const Icon(Icons.auto_awesome), title: const Text('Smart playlist'), subtitle: const Text('Fills itself from rules (genre, plays, added...)'), onTap: () => Navigator.pop(c, 'smart')),
        ]),
      ),
    );
    if (choice == null || !context.mounted) return;
    final s = context.read<AppServices>();
    if (choice == 'manual') {
      final name = await promptText(context, title: 'New playlist', hint: 'Name');
      if (name != null) await s.repo.createPlaylist(name);
    } else {
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SmartPlaylistEditor()));
    }
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
          if (t == null) return const Center(child: CircularProgressIndicator());
          if (t.isEmpty) return const EmptyState(icon: Icons.music_off, title: 'Nothing here yet');
          return TrackListView(tracks: t, padding: const EdgeInsets.only(bottom: 120));
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
        if (d == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
        final p = d.p;
        if (p == null) return Scaffold(appBar: AppBar(), body: const EmptyState(icon: Icons.queue_music, title: 'Playlist not found'));
        final tracks = [for (final e in d.entries) e.track];
        return Scaffold(
          appBar: AppBar(
            title: Text(p.name),
            actions: [
              if (p.isSmart) IconButton(tooltip: 'Edit rules', icon: const Icon(Icons.tune), onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SmartPlaylistEditor(existing: p)))),
              PopupMenuButton<String>(
                onSelected: (v) async {
                  if (v == 'rename') {
                    final n = await promptText(context, title: 'Rename', initial: p.name);
                    if (n != null) await s.repo.renamePlaylist(p.id, n);
                  } else if (v == 'delete') {
                    await s.repo.deletePlaylist(p.id);
                    if (context.mounted) Navigator.pop(context);
                  } else if (v == 'queue') {
                    await s.player.enqueue(tracks);
                  }
                },
                itemBuilder: (_) => const [PopupMenuItem(value: 'rename', child: Text('Rename')), PopupMenuItem(value: 'queue', child: Text('Add to queue')), PopupMenuItem(value: 'delete', child: Text('Delete'))],
              ),
            ],
          ),
          body: tracks.isEmpty
              ? EmptyState(icon: Icons.queue_music, title: 'Empty playlist', message: p.isSmart ? 'No songs match the rules yet.' : 'Add songs from the ⋮ menu of any track.')
              : Column(children: [
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Row(children: [
                      FilledButton.icon(onPressed: () => s.player.playTracks(tracks), icon: const Icon(Icons.play_arrow), label: const Text('Play')),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(onPressed: () => s.player.playTracks(tracks, shuffle: true), icon: const Icon(Icons.shuffle), label: const Text('Shuffle')),
                    ]),
                  ),
                  Expanded(
                    child: p.isSmart
                        ? TrackListView(tracks: tracks, padding: const EdgeInsets.only(bottom: 120))
                        : ReorderableListView.builder(
                            padding: const EdgeInsets.only(bottom: 120),
                            itemCount: d.entries.length,
                            onReorderItem: (o, n) => s.repo.reorderPlaylist(p.id, o, n),
                            itemBuilder: (context, i) {
                              final e = d.entries[i];
                              return TrackTile(
                                key: ValueKey('e${e.entryId}'),
                                track: e.track,
                                playlistId: p.id,
                                playlistEntryId: e.entryId,
                                onTap: () => s.player.playTracks(tracks, index: i),
                                trailing: ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_handle)),
                              );
                            },
                          ),
                  ),
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
  late SmartRules _rules = SmartRules.parse(widget.existing?.smartRules);
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
