import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../app/app_services.dart';
import '../../../core/library/album_grouping.dart';
import '../../../core/library/library_health.dart';
import '../../../core/models/library_models.dart';
import '../../../features/library/library_editor.dart';
import '../../widgets/common.dart';
import '../../widgets/cover_art.dart';
import 'album_editor.dart';
import 'dashboard_widgets.dart';

enum AlbumFilter {
  all('All'),
  noCover('No cover'),
  noYear('No year'),
  noArtist('No artist'),
  compilations('Compilations'),
  duplicates('Duplicates');

  const AlbumFilter(this.label);
  final String label;
}

enum _AlbumSort { title, artist, year, songs }

/// Searchable, filterable list of every album with multi-select bulk actions.
class AlbumManager extends StatefulWidget {
  const AlbumManager({super.key, required this.filter});

  /// Shared with the overview so "N albums without a cover" can jump straight to that filter.
  final ValueNotifier<AlbumFilter> filter;

  @override
  State<AlbumManager> createState() => _AlbumManagerState();
}

class _AlbumManagerState extends State<AlbumManager> {
  late final Stream<List<Album>> _albums = context.read<AppServices>().db.watch(() => context.read<AppServices>().repo.albums());
  String _query = '';
  _AlbumSort _sort = _AlbumSort.title;
  final Set<int> _selected = {};
  bool _busy = false;

  bool get _selecting => _selected.isNotEmpty;

  bool _noCover(AppServices s, Album a) => s.coverCache.albumCover(a.id) == null;

  bool _matches(AlbumFilter f, AppServices s, Album a, Set<int> dups) => switch (f) {
    AlbumFilter.all => true,
    AlbumFilter.noCover => _noCover(s, a),
    AlbumFilter.noYear => a.year == null,
    AlbumFilter.noArtist => a.artistName == null || a.artistName!.isEmpty,
    AlbumFilter.compilations => a.compilation,
    AlbumFilter.duplicates => dups.contains(a.id),
  };

  List<Album> _visible(AppServices s, List<Album> all, AlbumFilter f, Set<int> dups) {
    final q = normalizeName(_query);
    final list = all.where((a) => _matches(f, s, a, dups) && (q.isEmpty || normalizeName('${a.title} ${a.artistName ?? ''}').contains(q))).toList();
    int byTitle(Album a, Album b) => a.title.toLowerCase().compareTo(b.title.toLowerCase());
    if (f == AlbumFilter.duplicates) {
      list.sort(compareAlbumsByKey); // put the copies next to each other
    } else {
      switch (_sort) {
        case _AlbumSort.title:
          list.sort(byTitle);
        case _AlbumSort.artist:
          list.sort((a, b) => _then(a.displayArtist.toLowerCase().compareTo(b.displayArtist.toLowerCase()), byTitle(a, b)));
        case _AlbumSort.year:
          list.sort((a, b) => _then((b.year ?? 0).compareTo(a.year ?? 0), byTitle(a, b)));
        case _AlbumSort.songs:
          list.sort((a, b) => _then(b.trackCount.compareTo(a.trackCount), byTitle(a, b)));
      }
    }
    return list;
  }

  void _toggle(int id) => setState(() => _selected.contains(id) ? _selected.remove(id) : _selected.add(id));

  Future<void> _open(Album a) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AlbumEditorScreen(albumId: a.id)));
  }

  // ---------------------------------------------------------------- bulk actions

  Future<void> _merge(List<Album> all) async {
    final chosen = [
      for (final a in all)
        if (_selected.contains(a.id)) a,
    ];
    if (chosen.length < 2) return;
    final idx = await chooseMergeSurvivor(context, noun: 'albums', names: [for (final a in chosen) '${a.title} - ${a.displayArtist} (${a.trackCount})']);
    if (idx == null || !mounted) return;
    final s = context.read<AppServices>();
    setState(() => _busy = true);
    try {
      var report = const EditReport();
      for (var i = 0; i < chosen.length; i++) {
        if (i == idx) continue;
        report += await s.editor.mergeAlbums(chosen[i], chosen[idx]);
      }
      if (mounted) {
        showSnack(context, report.describe('Merge'));
        setState(_selected.clear);
      }
    } on Object catch (e) {
      if (mounted) showSnack(context, 'Could not merge: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _fetchCovers() async {
    final s = context.read<AppServices>();
    final ids = _selected.toList();
    setState(() => _busy = true);
    var found = 0;
    try {
      for (var i = 0; i < ids.length; i++) {
        if (mounted) showSnack(context, 'Looking for covers… ${i + 1}/${ids.length}', duration: const Duration(seconds: 30));
        final album = await s.repo.albumById(ids[i]);
        if (album == null) continue;
        try {
          if (await s.covers.ensureAlbumCover(album, force: true) != null) found++;
        } on Object {
          // offline or provider trouble: leave that one on the placeholder
        }
        s.coverCache.retry(ids[i]);
      }
      if (mounted) {
        showSnack(context, 'Found $found of ${ids.length} covers');
        setState(_selected.clear);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _bulkEdit() async {
    final artist = TextEditingController();
    final genre = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Edit ${plural(_selected.length, 'album')}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Leave a field empty to keep each album\'s current value.'),
            const SizedBox(height: 12),
            TextField(
              controller: artist,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Album artist'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: genre,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Genre'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Apply')),
        ],
      ),
    );
    final newArtist = artist.text.trim();
    final newGenre = genre.text.trim();
    artist.dispose();
    genre.dispose();
    if (ok != true || (newArtist.isEmpty && newGenre.isEmpty) || !mounted) return;
    final s = context.read<AppServices>();
    setState(() => _busy = true);
    var done = 0;
    var report = const EditReport();
    try {
      for (final id in _selected.toList()) {
        final album = await s.repo.albumById(id);
        if (album == null) continue;
        final r = await s.editor.editAlbum(album, albumArtist: newArtist.isEmpty ? null : newArtist, genre: newGenre.isEmpty ? null : newGenre);
        done++;
        report += r;
      }
      if (mounted) {
        showSnack(context, report.describe(plural(done, 'album')));
        setState(_selected.clear);
      }
    } on Object catch (e) {
      if (mounted) showSnack(context, 'Could not save: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ------------------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    final t = Theme.of(context);
    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(_selected.clear);
      },
      child: StreamBuilder<List<Album>>(
        stream: _albums,
        builder: (context, snap) {
          final all = snap.data;
          if (all == null) return const Center(child: CircularProgressIndicator());
          return ListenableBuilder(
            listenable: Listenable.merge([s.coverCache, widget.filter]),
            builder: (context, _) {
              final f = widget.filter.value;
              final dups = duplicateAlbumIds(all);
              final counts = {for (final v in AlbumFilter.values) v: all.where((a) => _matches(v, s, a, dups)).length};
              final list = _visible(s, all, f, dups);
              // selection may refer to albums that no longer exist (merged away)
              _selected.removeWhere((id) => !all.any((a) => a.id == id));
              return Column(
                children: [
                  if (_selecting)
                    _selectionBar(context, all)
                  else ...[
                    ManagerSearchField(hint: 'Search albums or artists', onChanged: (v) => setState(() => _query = v)),
                    FilterChipsRow<AlbumFilter>(values: AlbumFilter.values, selected: f, label: (v) => v.label, counts: counts, onSelected: (v) => widget.filter.value = v),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 4, 0),
                      child: Row(
                        children: [
                          Text(plural(list.length, 'album'), style: t.textTheme.labelLarge?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                          const Spacer(),
                          if (f != AlbumFilter.duplicates)
                            PopupMenuButton<_AlbumSort>(
                              tooltip: 'Sort',
                              icon: const Icon(Icons.sort),
                              initialValue: _sort,
                              onSelected: (v) => setState(() => _sort = v),
                              itemBuilder: (_) => const [
                                PopupMenuItem(value: _AlbumSort.title, child: Text('Title')),
                                PopupMenuItem(value: _AlbumSort.artist, child: Text('Artist')),
                                PopupMenuItem(value: _AlbumSort.year, child: Text('Year (newest)')),
                                PopupMenuItem(value: _AlbumSort.songs, child: Text('Most songs')),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ],
                  if (_busy) const LinearProgressIndicator(),
                  if (f == AlbumFilter.duplicates && !_selecting && list.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text('Copies sit next to each other. Long-press two or more, then choose Merge.', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                    ),
                  Expanded(
                    child: list.isEmpty
                        ? EmptyState(
                            icon: f == AlbumFilter.all ? Icons.album_outlined : Icons.check_circle_outline,
                            title: f == AlbumFilter.all ? 'No albums match' : 'Nothing to fix here',
                            message: f == AlbumFilter.all ? null : 'No albums are flagged as "${f.label.toLowerCase()}".',
                          )
                        : ListView.builder(padding: const EdgeInsets.only(bottom: 120), itemCount: list.length, itemBuilder: (context, i) => _row(context, s, list[i])),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _row(BuildContext context, AppServices s, Album a) {
    final t = Theme.of(context);
    final sel = _selected.contains(a.id);
    final issues = [if (_noCover(s, a)) 'No cover', if (a.year == null) 'No year'];
    return ListTile(
      selected: sel,
      selectedTileColor: t.colorScheme.primaryContainer.withValues(alpha: 0.45),
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          CoverArt(albumId: a.id, seed: a.title, size: 52),
          if (sel)
            Positioned(
              right: -4,
              bottom: -4,
              child: CircleAvatar(
                radius: 10,
                backgroundColor: t.colorScheme.primary,
                child: Icon(Icons.check, size: 14, color: t.colorScheme.onPrimary),
              ),
            ),
        ],
      ),
      title: Text(a.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text([a.displayArtist, if (a.year != null) '${a.year}', plural(a.trackCount, 'song')].join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis),
          if (issues.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(spacing: 6, children: [for (final i in issues) IssuePill(i)]),
            ),
        ],
      ),
      trailing: _selecting ? null : const Icon(Icons.edit_outlined, size: 20),
      onTap: _busy ? null : () => _selecting ? _toggle(a.id) : _open(a),
      onLongPress: _busy ? null : () => _toggle(a.id),
    );
  }

  Widget _selectionBar(BuildContext context, List<Album> all) {
    final t = Theme.of(context);
    return Material(
      color: t.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
        child: Row(
          children: [
            IconButton(tooltip: 'Clear selection', icon: const Icon(Icons.close), onPressed: () => setState(_selected.clear)),
            Text('${_selected.length} selected', style: t.textTheme.titleSmall?.copyWith(color: t.colorScheme.onSecondaryContainer)),
            const Spacer(),
            IconButton(tooltip: 'Select all shown', icon: const Icon(Icons.select_all), onPressed: _busy ? null : () => setState(() => _selected.addAll(all.map((a) => a.id)))),
            IconButton(tooltip: 'Edit artist / genre', icon: const Icon(Icons.edit_note), onPressed: _busy ? null : _bulkEdit),
            IconButton(tooltip: 'Find covers', icon: const Icon(Icons.image_search), onPressed: _busy ? null : _fetchCovers),
            IconButton(tooltip: 'Merge', icon: const Icon(Icons.merge_type), onPressed: (_busy || _selected.length < 2) ? null : () => _merge(all)),
          ],
        ),
      ),
    );
  }
}

/// Falls back to [next] when a comparison ties.
int _then(int c, int next) => c != 0 ? c : next;
