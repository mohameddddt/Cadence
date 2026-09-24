import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../app/app_services.dart';
import '../../../core/library/album_grouping.dart';
import '../../../core/library/library_health.dart';
import '../../../core/models/library_models.dart';
import '../../../features/library/library_editor.dart';
import '../../widgets/common.dart';
import '../../widgets/cover_art.dart';
import 'artist_editor.dart';
import 'dashboard_widgets.dart';

enum ArtistFilter {
  all('All'),
  noPhoto('No photo'),
  noBio('No bio'),
  followed('Alerts on'),
  duplicates('Duplicates');

  const ArtistFilter(this.label);
  final String label;
}

enum _ArtistSort { name, songs, albums }

/// Searchable, filterable list of every artist with multi-select bulk actions.
class ArtistManager extends StatefulWidget {
  const ArtistManager({super.key, required this.filter});

  /// Shared with the overview so "N artists without a photo" can jump straight to that filter.
  final ValueNotifier<ArtistFilter> filter;

  @override
  State<ArtistManager> createState() => _ArtistManagerState();
}

class _ArtistManagerState extends State<ArtistManager> {
  late final Stream<List<Artist>> _artists = context.read<AppServices>().db.watch(() => context.read<AppServices>().repo.artists());
  String _query = '';
  _ArtistSort _sort = _ArtistSort.name;
  final Set<int> _selected = {};
  bool _busy = false;

  bool get _selecting => _selected.isNotEmpty;

  bool _noPhoto(AppServices s, Artist a) => s.coverCache.artistImage(a.id) == null;

  bool _matches(ArtistFilter f, AppServices s, Artist a, Set<int> dups) => switch (f) {
    ArtistFilter.all => true,
    ArtistFilter.noPhoto => _noPhoto(s, a),
    ArtistFilter.noBio => a.bio == null || a.bio!.trim().isEmpty,
    ArtistFilter.followed => a.followed,
    ArtistFilter.duplicates => dups.contains(a.id),
  };

  List<Artist> _visible(AppServices s, List<Artist> all, ArtistFilter f, Set<int> dups) {
    final q = normalizeName(foldDiacritics(_query));
    final list = all.where((a) => _matches(f, s, a, dups) && (q.isEmpty || normalizeName(foldDiacritics(a.name)).contains(q))).toList();
    if (f == ArtistFilter.duplicates) {
      list.sort(compareArtistsByKey); // put the copies next to each other
    } else {
      switch (_sort) {
        case _ArtistSort.name:
          break; // the repository already returns them by sort name
        case _ArtistSort.songs:
          list.sort((a, b) => b.trackCount.compareTo(a.trackCount));
        case _ArtistSort.albums:
          list.sort((a, b) => b.albumCount.compareTo(a.albumCount));
      }
    }
    return list;
  }

  void _toggle(int id) => setState(() => _selected.contains(id) ? _selected.remove(id) : _selected.add(id));

  Future<void> _open(Artist a) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ArtistEditorScreen(artistId: a.id)));

  // ---------------------------------------------------------------- bulk actions

  Future<void> _merge(List<Artist> all) async {
    final chosen = [
      for (final a in all)
        if (_selected.contains(a.id)) a,
    ];
    if (chosen.length < 2) return;
    final idx = await chooseMergeSurvivor(context, noun: 'artists', names: [for (final a in chosen) '${a.name} (${a.trackCount} songs)']);
    if (idx == null || !mounted) return;
    final s = context.read<AppServices>();
    setState(() => _busy = true);
    try {
      var report = const EditReport();
      for (var i = 0; i < chosen.length; i++) {
        if (i == idx) continue;
        report += await s.editor.mergeArtists(chosen[i], chosen[idx]);
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

  Future<void> _refreshInfo() async {
    final s = context.read<AppServices>();
    final ids = _selected.toList();
    setState(() => _busy = true);
    var updated = 0;
    try {
      for (var i = 0; i < ids.length; i++) {
        if (mounted) showSnack(context, 'Looking up artists… ${i + 1}/${ids.length}', duration: const Duration(seconds: 30));
        final artist = await s.repo.artistById(ids[i]);
        if (artist == null) continue;
        try {
          await s.artistInfo.refresh(artist);
          updated++;
        } on Object {
          // offline or provider trouble: keep what is there
        }
      }
      LibraryEditor.evictImages();
      if (mounted) {
        showSnack(context, 'Looked up $updated of ${ids.length} artists');
        setState(_selected.clear);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleFollow(List<Artist> all) async {
    final s = context.read<AppServices>();
    final chosen = [
      for (final a in all)
        if (_selected.contains(a.id)) a,
    ];
    final follow = chosen.any((a) => !a.followed);
    for (final a in chosen) {
      await s.repo.updateArtist(a.id, followed: follow);
    }
    if (mounted) {
      showSnack(context, follow ? 'Release alerts on for ${chosen.length} artists' : 'Release alerts off for ${chosen.length} artists');
      setState(_selected.clear);
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
      child: StreamBuilder<List<Artist>>(
        stream: _artists,
        builder: (context, snap) {
          final all = snap.data;
          if (all == null) return const Center(child: CircularProgressIndicator());
          return ListenableBuilder(
            listenable: Listenable.merge([s.coverCache, widget.filter]),
            builder: (context, _) {
              final f = widget.filter.value;
              final dups = duplicateArtistIds(all);
              final counts = {for (final v in ArtistFilter.values) v: all.where((a) => _matches(v, s, a, dups)).length};
              final list = _visible(s, all, f, dups);
              _selected.removeWhere((id) => !all.any((a) => a.id == id));
              return Column(
                children: [
                  if (_selecting)
                    _selectionBar(context, list, all)
                  else ...[
                    ManagerSearchField(hint: 'Search artists', onChanged: (v) => setState(() => _query = v)),
                    FilterChipsRow<ArtistFilter>(values: ArtistFilter.values, selected: f, label: (v) => v.label, counts: counts, onSelected: (v) => widget.filter.value = v),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 4, 0),
                      child: Row(
                        children: [
                          Text(plural(list.length, 'artist'), style: t.textTheme.labelLarge?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                          const Spacer(),
                          if (f != ArtistFilter.duplicates)
                            PopupMenuButton<_ArtistSort>(
                              tooltip: 'Sort',
                              icon: const Icon(Icons.sort),
                              initialValue: _sort,
                              onSelected: (v) => setState(() => _sort = v),
                              itemBuilder: (_) => const [
                                PopupMenuItem(value: _ArtistSort.name, child: Text('Name')),
                                PopupMenuItem(value: _ArtistSort.songs, child: Text('Most songs')),
                                PopupMenuItem(value: _ArtistSort.albums, child: Text('Most albums')),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ],
                  if (_busy) const LinearProgressIndicator(),
                  if (f == ArtistFilter.duplicates && !_selecting && list.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text(
                        'Spellings of the same artist sit next to each other. Long-press them, then choose Merge.',
                        style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                      ),
                    ),
                  Expanded(
                    child: list.isEmpty
                        ? EmptyState(
                            icon: f == ArtistFilter.all ? Icons.person_search_outlined : Icons.check_circle_outline,
                            title: f == ArtistFilter.all ? 'No artists match' : 'Nothing to fix here',
                            message: f == ArtistFilter.all ? null : 'No artists are flagged as "${f.label.toLowerCase()}".',
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

  Widget _row(BuildContext context, AppServices s, Artist a) {
    final t = Theme.of(context);
    final sel = _selected.contains(a.id);
    final issues = [if (_noPhoto(s, a)) 'No photo', if (a.bio == null || a.bio!.trim().isEmpty) 'No bio'];
    return ListTile(
      selected: sel,
      selectedTileColor: t.colorScheme.primaryContainer.withValues(alpha: 0.45),
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          CoverArt(artistId: a.id, seed: a.name, size: 52, circle: true),
          if (sel)
            Positioned(
              right: -2,
              bottom: -2,
              child: CircleAvatar(
                radius: 10,
                backgroundColor: t.colorScheme.primary,
                child: Icon(Icons.check, size: 14, color: t.colorScheme.onPrimary),
              ),
            ),
        ],
      ),
      title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${plural(a.albumCount, 'album')} · ${plural(a.trackCount, 'song')}', maxLines: 1, overflow: TextOverflow.ellipsis),
          if (issues.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(spacing: 6, children: [for (final i in issues) IssuePill(i)]),
            ),
        ],
      ),
      trailing: _selecting
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (a.followed) Icon(Icons.notifications_active, size: 18, color: t.colorScheme.primary),
                const SizedBox(width: 8),
                const Icon(Icons.edit_outlined, size: 20),
              ],
            ),
      onTap: _busy ? null : () => _selecting ? _toggle(a.id) : _open(a),
      onLongPress: _busy ? null : () => _toggle(a.id),
    );
  }

  Widget _selectionBar(BuildContext context, List<Artist> shown, List<Artist> all) {
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
            IconButton(tooltip: 'Select all shown', icon: const Icon(Icons.select_all), onPressed: _busy ? null : () => setState(() => _selected.addAll(shown.map((a) => a.id)))),
            IconButton(tooltip: 'Toggle release alerts', icon: const Icon(Icons.notifications_outlined), onPressed: _busy ? null : () => _toggleFollow(all)),
            IconButton(tooltip: 'Look up photo and bio', icon: const Icon(Icons.cloud_download_outlined), onPressed: _busy ? null : _refreshInfo),
            IconButton(tooltip: 'Merge', icon: const Icon(Icons.merge_type), onPressed: (_busy || _selected.length < 2) ? null : () => _merge(all)),
          ],
        ),
      ),
    );
  }
}
