import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../app/app_services.dart';
import '../../../core/library/library_repository.dart';
import '../../../core/models/library_models.dart';
import '../../../features/library/library_editor.dart';
import '../../widgets/common.dart';
import '../../widgets/cover_art.dart';
import '../artist_screen.dart';
import 'album_editor.dart';
import 'dashboard_widgets.dart';

/// Edit an artist: name (renames every song), sort name, bio, photo, release alerts, or merge
/// into another artist.
class ArtistEditorScreen extends StatefulWidget {
  const ArtistEditorScreen({super.key, required this.artistId});
  final int artistId;

  @override
  State<ArtistEditorScreen> createState() => _ArtistEditorScreenState();
}

class _ArtistEditorScreenState extends State<ArtistEditorScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _sort = TextEditingController();
  final _bio = TextEditingController();
  final _mbid = TextEditingController();

  Artist? _artist;
  List<Album> _albums = const [];
  bool _followed = false;
  bool _loading = true;
  bool _saving = false;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    for (final c in [_name, _sort, _bio, _mbid]) {
      c.addListener(_markDirty);
    }
    _load();
  }

  @override
  void dispose() {
    for (final c in [_name, _sort, _bio, _mbid]) {
      c.dispose();
    }
    super.dispose();
  }

  String _autoSort(String name) => LibraryRepository.sortName(name.trim());

  void _markDirty() {
    final a = _artist;
    if (a == null || _loading) return;
    final dirty =
        _name.text.trim() != a.name ||
        _sort.text.trim() != (a.sortName ?? _autoSort(a.name)) ||
        _bio.text.trim() != (a.bio ?? '') ||
        _mbid.text.trim() != (a.mbArtistId ?? '') ||
        _followed != a.followed;
    if (dirty != _dirty) setState(() => _dirty = dirty);
  }

  Future<void> _load() async {
    final s = context.read<AppServices>();
    final artist = await s.repo.artistById(widget.artistId);
    final albums = await s.repo.albums(artistId: widget.artistId, orderBy: 'a.year DESC, a.title COLLATE NOCASE');
    if (!mounted) return;
    setState(() {
      _loading = true;
      _artist = artist;
      _albums = albums;
      if (artist != null) {
        _name.text = artist.name;
        _sort.text = artist.sortName ?? _autoSort(artist.name);
        _bio.text = artist.bio ?? '';
        _mbid.text = artist.mbArtistId ?? '';
        _followed = artist.followed;
      }
      _loading = false;
      _dirty = false;
    });
  }

  Future<void> _save() async {
    final artist = _artist;
    if (artist == null || !(_form.currentState?.validate() ?? false)) return;
    final s = context.read<AppServices>();
    final name = _name.text.trim();
    if (name != artist.name) {
      final existing = await s.repo.artistByName(name);
      if (existing != null && existing.id != artist.id) {
        if (!mounted) return;
        final ok = await confirm(
          context,
          title: 'Merge with "${existing.name}"?',
          message:
              'An artist with that name already exists. Saving folds "${artist.name}" into it: ${plural(artist.trackCount, 'song')} move over, and the existing artist keeps its own bio and photo.',
          action: 'Merge',
        );
        if (!ok) return;
      }
    }
    setState(() => _saving = true);
    try {
      var id = artist.id;
      EditReport? report;
      var merged = false;
      if (name != artist.name) {
        report = await s.editor.renameArtist(artist, name);
        id = report.id ?? id;
        merged = id != artist.id;
      }
      if (!merged) {
        final bio = _bio.text.trim();
        final renamed = name != artist.name;
        final oldSort = artist.sortName ?? _autoSort(artist.name);
        final typedSort = _sort.text.trim();
        // An untouched sort name belongs to the old spelling; a rename already re-derived it.
        final sort = (typedSort.isEmpty || (renamed && typedSort == oldSort)) ? _autoSort(name) : typedSort;
        final currentSort = renamed ? _autoSort(name) : oldSort;
        final mbid = _mbid.text.trim();
        await s.repo.updateArtistFields(id, {
          if (sort != currentSort) 'sort_name': sort,
          if (bio != (artist.bio ?? '')) ...{'bio': bio.isEmpty ? null : bio, 'bio_source': bio.isEmpty ? null : 'Edited by you'},
          if (mbid != (artist.mbArtistId ?? '')) 'mb_artist_id': mbid.isEmpty ? null : mbid,
          if (_followed != artist.followed) 'followed': _followed ? 1 : 0,
        });
      }
      if (!mounted) return;
      showSnack(context, report?.describe('Artist') ?? 'Artist saved');
      setState(() => _dirty = false);
      Navigator.pop(context, true);
    } on Object catch (e) {
      if (mounted) showSnack(context, 'Could not save: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _merge() async {
    final artist = _artist;
    if (artist == null) return;
    final target = await pickArtist(context, exclude: artist.id, title: 'Merge "${artist.name}" into…');
    if (target == null || !mounted) return;
    final ok = await confirm(
      context,
      title: 'Merge artists?',
      message: '"${artist.name}" (${plural(artist.trackCount, 'song')}) will be folded into "${target.name}". All its songs and albums move over and the name "${artist.name}" disappears.',
      action: 'Merge',
    );
    if (!ok || !mounted) return;
    setState(() => _saving = true);
    try {
      final report = await context.read<AppServices>().editor.mergeArtists(artist, target);
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

  Future<void> _changePhoto() async {
    final artist = _artist;
    if (artist == null) return;
    final s = context.read<AppServices>();
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(leading: const Icon(Icons.photo_library_outlined), title: const Text('Choose from device'), onTap: () => Navigator.pop(c, 'file')),
            ListTile(
              leading: const Icon(Icons.cloud_download_outlined),
              title: const Text('Fetch from the web'),
              subtitle: const Text('Looks the artist up again and replaces the photo and bio'),
              onTap: () => Navigator.pop(c, 'web'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    try {
      if (choice == 'file') {
        final r = await FilePicker.pickFile(type: FileType.image);
        if (r?.path == null) return;
        await s.editor.setArtistPhoto(artist, await File(r!.path!).readAsBytes());
        if (mounted) showSnack(context, 'Photo updated');
      } else {
        showSnack(context, 'Looking up ${artist.name}…');
        await s.artistInfo.refresh(artist, force: true);
        LibraryEditor.evictImages();
        if (mounted) {
          await _load();
          if (mounted) showSnack(context, 'Photo and bio refreshed');
        }
      }
    } on Object catch (e) {
      if (mounted) showSnack(context, 'Could not update the photo: $e');
    }
  }

  Future<void> _discardCheck(bool didPop) async {
    if (didPop) return;
    final ok = await confirm(context, title: 'Discard changes?', message: 'You have unsaved changes to this artist.', action: 'Discard');
    if (ok && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = context.read<AppServices>();
    final artist = _artist;
    if (artist == null) {
      return Scaffold(
        appBar: AppBar(),
        body: _loading ? const Center(child: CircularProgressIndicator()) : const EmptyState(icon: Icons.person_off, title: 'Artist not found'),
      );
    }
    final renaming = _name.text.trim().isNotEmpty && _name.text.trim() != artist.name;
    return PopScope(
      canPop: !_dirty || _saving,
      onPopInvokedWithResult: (didPop, _) => _discardCheck(didPop),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Edit artist'),
          actions: [
            IconButton(
              tooltip: 'Open artist',
              icon: const Icon(Icons.open_in_new),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ArtistScreen(artistId: artist.id))),
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
              Center(
                child: Stack(
                  children: [
                    CoverArt(artistId: artist.id, seed: artist.name, size: 128, circle: true),
                    Positioned(
                      right: 4,
                      bottom: 4,
                      child: Material(
                        color: t.colorScheme.primary,
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: _changePhoto,
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: Icon(Icons.edit, size: 18, color: t.colorScheme.onPrimary),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: Text('${plural(artist.albumCount, 'album')} · ${plural(artist.trackCount, 'song')}', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              ),
              const SizedBox(height: 20),
              TextFormField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: 'Name',
                  helperText: renaming ? 'Renames the artist on ${artist.trackCount == 1 ? 'its song' : 'all ${artist.trackCount} songs'}' : null,
                ),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'An artist needs a name' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _sort,
                decoration: InputDecoration(
                  labelText: 'Sort name',
                  helperText: renaming ? 'Recalculated from the new name unless you change it after saving' : 'How the artist is ordered in lists, e.g. "Beatles, The"',
                  helperMaxLines: 2,
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _bio,
                minLines: 4,
                maxLines: 10,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Bio', alignLabelWithHint: true),
              ),
              const SizedBox(height: 4),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('New release alerts'),
                subtitle: const Text('Get notified when this artist puts out something new'),
                value: _followed,
                onChanged: (v) {
                  setState(() => _followed = v);
                  _markDirty();
                },
              ),
              Theme(
                data: t.copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const Text('Advanced'),
                  children: [
                    TextFormField(
                      controller: _mbid,
                      decoration: const InputDecoration(labelText: 'MusicBrainz artist id', helperText: 'Used for photos, bios, discography and release alerts'),
                      validator: (v) {
                        final x = v?.trim() ?? '';
                        return x.isEmpty || RegExp(r'^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$').hasMatch(x) ? null : 'That is not a MusicBrainz id';
                      },
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
              if (_albums.isNotEmpty) ...[
                const SectionHeader('Albums'),
                Card(
                  child: Column(
                    children: [
                      for (var i = 0; i < _albums.length; i++) ...[
                        if (i > 0) const Divider(height: 1),
                        ListTile(
                          leading: CoverArt(albumId: _albums[i].id, seed: _albums[i].title, size: 44),
                          title: Text(_albums[i].title, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text([if (_albums[i].year != null) '${_albums[i].year}', plural(_albums[i].trackCount, 'song')].join(' · ')),
                          trailing: const Icon(Icons.edit_outlined, size: 18),
                          onTap: () async {
                            await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AlbumEditorScreen(albumId: _albums[i].id)));
                            if (mounted && !_dirty) _load();
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              ],
              const SectionHeader('More'),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.merge_type),
                  title: const Text('Merge into another artist…'),
                  subtitle: const Text('For duplicates such as "AC/DC" and "AC DC"'),
                  onTap: _saving ? null : _merge,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  s.settings.writeTagsToFiles
                      ? 'Renames are written into the audio files too. Bio, photo and alerts live in Cadence only.'
                      : 'Tag writing is off (Settings → Metadata), so a rename stays inside Cadence.',
                  style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
