import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../app/app_services.dart';
import '../../../core/library/smart_rules.dart';
import '../../../core/models/library_models.dart';
import '../../../core/models/track.dart';
import '../../widgets/common.dart';
import '../../widgets/cover_art.dart';
import '../album_screen.dart';
import '../identify_screens.dart';
import '../tag_editor_screen.dart';
import 'dashboard_widgets.dart';

/// Edit an album: title, album artist, year, genre, cover, its songs, or merge it into another album.
class AlbumEditorScreen extends StatefulWidget {
  const AlbumEditorScreen({super.key, required this.albumId});
  final int albumId;

  @override
  State<AlbumEditorScreen> createState() => _AlbumEditorScreenState();
}

class _AlbumEditorScreenState extends State<AlbumEditorScreen> {
  final _form = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _artist = TextEditingController();
  final _year = TextEditingController();
  final _genre = TextEditingController();

  Album? _album;
  List<Track> _tracks = const [];
  String _genreInitial = '';
  bool _mixedGenres = false;
  bool _loading = true;
  bool _saving = false;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    for (final c in [_title, _artist, _year, _genre]) {
      c.addListener(_markDirty);
    }
    _load(initial: true);
  }

  @override
  void dispose() {
    for (final c in [_title, _artist, _year, _genre]) {
      c.dispose();
    }
    super.dispose();
  }

  void _markDirty() {
    final a = _album;
    if (a == null || _loading) return;
    final dirty = _title.text.trim() != a.title || _artist.text.trim() != (a.artistName ?? '') || _year.text.trim() != (a.year?.toString() ?? '') || _genre.text.trim() != _genreInitial;
    if (dirty != _dirty) setState(() => _dirty = dirty);
  }

  Future<void> _load({bool initial = false}) async {
    final s = context.read<AppServices>();
    final album = await s.repo.albumById(widget.albumId);
    final tracks = await s.repo.tracks(albumId: widget.albumId, sort: TrackSort.album);
    if (!mounted) return;
    setState(() {
      _album = album;
      _tracks = tracks;
      if (initial && album != null) {
        _loading = true; // hold dirty tracking while the fields are filled in
        _title.text = album.title;
        _artist.text = album.artistName ?? '';
        _year.text = album.year?.toString() ?? '';
        final genres = {for (final t in tracks) (t.genre ?? '').trim()};
        _mixedGenres = genres.length > 1;
        _genreInitial = genres.length == 1 ? genres.first : '';
        _genre.text = _genreInitial;
      }
      _loading = false;
    });
  }

  Future<void> _save() async {
    final album = _album;
    if (album == null || !(_form.currentState?.validate() ?? false)) return;
    final s = context.read<AppServices>();
    setState(() => _saving = true);
    try {
      final yearText = _year.text.trim();
      final report = await s.editor.editAlbum(
        album,
        title: _title.text,
        albumArtist: _artist.text,
        year: yearText.isEmpty ? (album.year == null ? null : 0) : int.parse(yearText),
        genre: _genre.text.trim() == _genreInitial ? null : _genre.text,
      );
      if (!mounted) return;
      showSnack(context, report.describe('Album'));
      setState(() => _dirty = false);
      Navigator.pop(context, true);
    } on Object catch (e) {
      if (mounted) showSnack(context, 'Could not save: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _merge() async {
    final album = _album;
    if (album == null) return;
    final target = await pickAlbum(context, exclude: album.id, title: 'Merge "${album.title}" into…');
    if (target == null || !mounted) return;
    final ok = await confirm(
      context,
      title: 'Merge albums?',
      message:
          '"${album.title}" (${plural(album.trackCount, 'song')}) will be folded into "${target.title}" by ${target.displayArtist}. Its songs take the target\'s title and album artist.',
      action: 'Merge',
    );
    if (!ok || !mounted) return;
    setState(() => _saving = true);
    try {
      final report = await context.read<AppServices>().editor.mergeAlbums(album, target);
      if (!mounted) return;
      showSnack(context, report.describe('Merge'));
      Navigator.pop(context, true);
    } on Object catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showSnack(context, 'Could not merge: $e');
      }
    }
  }

  Future<void> _discardCheck(bool didPop) async {
    if (didPop) return;
    final ok = await confirm(context, title: 'Discard changes?', message: 'You have unsaved changes to this album.', action: 'Discard');
    if (ok && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = context.read<AppServices>();
    final album = _album;
    if (album == null) {
      return Scaffold(
        appBar: AppBar(),
        body: _loading ? const Center(child: CircularProgressIndicator()) : const EmptyState(icon: Icons.album, title: 'Album not found'),
      );
    }
    final writing = s.settings.writeTagsToFiles;
    return PopScope(
      canPop: !_dirty || _saving,
      onPopInvokedWithResult: (didPop, _) => _discardCheck(didPop),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Edit album'),
          actions: [
            IconButton(
              tooltip: 'Open album',
              icon: const Icon(Icons.open_in_new),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AlbumScreen(albumId: album.id))),
            ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: FilledButton.icon(
              onPressed: (_dirty && !_saving) ? _save : null,
              icon: _saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.check),
              label: Text(_saving ? 'Saving…' : 'Save changes'),
            ),
          ),
        ),
        body: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Stack(
                    children: [
                      CoverArt(albumId: album.id, seed: album.title, size: 128, radius: 20),
                      Positioned(
                        right: 6,
                        bottom: 6,
                        child: Material(
                          color: t.colorScheme.primary,
                          shape: const CircleBorder(),
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: () => changeAlbumCover(context, album),
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Icon(Icons.edit, size: 18, color: t.colorScheme.onPrimary),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${plural(album.trackCount, 'song')} · ${formatMs(album.durationMs)}', style: t.textTheme.titleSmall),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            if (album.year == null) const IssuePill('No year'),
                            if (album.artistName == null) const IssuePill('No artist'),
                            if (album.compilation) const IssuePill('Compilation'),
                          ],
                        ),
                        const SizedBox(height: 4),
                        TextButton.icon(
                          style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                          onPressed: () => changeAlbumCover(context, album),
                          icon: const Icon(Icons.image_outlined, size: 18),
                          label: const Text('Change cover'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              TextFormField(
                controller: _title,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Title'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'An album needs a title' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _artist,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  labelText: 'Album artist',
                  helperText: 'The name shown under the album. Use "Various Artists" for compilations.',
                  helperMaxLines: 2,
                  suffixIcon: IconButton(tooltip: 'Mark as compilation', icon: const Icon(Icons.groups_outlined), onPressed: () => _artist.text = 'Various Artists'),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _year,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Year'),
                      validator: (v) {
                        final x = v?.trim() ?? '';
                        if (x.isEmpty) return null;
                        final n = int.tryParse(x);
                        return (n == null || n < 1000 || n > 2100) ? 'Use a 4-digit year' : null;
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: TextFormField(
                      controller: _genre,
                      textCapitalization: TextCapitalization.words,
                      decoration: InputDecoration(labelText: 'Genre', hintText: _mixedGenres ? 'Mixed - type to set all' : null),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(writing ? Icons.save_outlined : Icons.info_outline, size: 18, color: t.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      writing
                          ? 'Changes are written into ${_tracks.length == 1 ? 'the audio file' : 'the ${_tracks.length} audio files'} too, so other players and a rescan agree. Android may ask once for permission.'
                          : 'Tag writing is off (Settings → Metadata), so changes stay inside Cadence.',
                      style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
              const SectionHeader('Songs'),
              Card(
                child: Column(
                  children: [
                    for (final tr in _tracks)
                      ListTile(
                        dense: true,
                        leading: SizedBox(
                          width: 28,
                          child: Text(
                            '${tr.trackNo ?? '–'}',
                            textAlign: TextAlign.center,
                            style: t.textTheme.labelLarge?.copyWith(color: t.colorScheme.onSurfaceVariant, fontFeatures: tabularFigures),
                          ),
                        ),
                        title: Text(tr.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text('${tr.displayArtist} · ${formatMs(tr.durationMs)}', maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: const Icon(Icons.edit_outlined, size: 18),
                        onTap: () async {
                          await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => TagEditorScreen(track: tr)));
                          if (mounted) _load();
                        },
                      ),
                  ],
                ),
              ),
              const SectionHeader('More'),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.auto_fix_high),
                      title: const Text('Identify with MusicBrainz'),
                      subtitle: const Text('Fill in tags and the release for every song'),
                      onTap: () async {
                        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => FixTagsScreen(initial: _tracks)));
                        if (mounted) _load();
                      },
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.merge_type),
                      title: const Text('Merge into another album…'),
                      subtitle: const Text('For an album that got split, e.g. "Live" and "Live (Deluxe)"'),
                      onTap: _saving ? null : _merge,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
