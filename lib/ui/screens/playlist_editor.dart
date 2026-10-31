import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/app_services.dart';
import '../../core/models/library_models.dart';
import '../../features/cover/image_processing.dart';
import '../widgets/common.dart';
import '../widgets/kit.dart';

/// A playlist's picture: the one the user chose, or a gradient made from its name.
class PlaylistCover extends StatelessWidget {
  const PlaylistCover({super.key, required this.playlist, this.size = 56, this.radius = 14});

  final Playlist playlist;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final path = playlist.coverPath;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox.square(
        dimension: size,
        child: path != null && File(path).existsSync()
            ? Image.file(File(path), fit: BoxFit.cover, cacheWidth: (size * dpr).round(), gaplessPlayback: true, excludeFromSemantics: true)
            : _GradientCover(seed: playlist.name, icon: playlist.isSmart ? Icons.auto_awesome_rounded : Icons.queue_music_rounded, size: size),
      ),
    );
  }
}

class _GradientCover extends StatelessWidget {
  const _GradientCover({required this.seed, required this.icon, required this.size});

  final String seed;
  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = placeholderColors(seed, Theme.of(context).brightness);
    return DecoratedBox(
      decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [c.a, c.b])),
      child: Icon(icon, size: size * 0.38, color: Colors.white.withValues(alpha: 0.9)),
    );
  }
}

/// Create a playlist (no [existing]) or edit one's name and picture.
/// Returns the playlist id, or null when cancelled.
Future<int?> showPlaylistEditor(BuildContext context, {Playlist? existing}) => showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _PlaylistEditorSheet(existing: existing),
    );

class _PlaylistEditorSheet extends StatefulWidget {
  const _PlaylistEditorSheet({this.existing});
  final Playlist? existing;

  @override
  State<_PlaylistEditorSheet> createState() => _PlaylistEditorSheetState();
}

class _PlaylistEditorSheetState extends State<_PlaylistEditorSheet> {
  late final TextEditingController _name = TextEditingController(text: widget.existing?.name ?? '');

  /// Newly picked picture (square JPEG), not saved yet.
  Uint8List? _picked;

  /// The existing picture should be removed on save.
  bool _removed = false;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  String? get _existingPath {
    final p = widget.existing?.coverPath;
    return !_removed && p != null && File(p).existsSync() ? p : null;
  }

  bool get _hasPicture => _picked != null || _existingPath != null;

  Future<void> _pick() async {
    final r = await FilePicker.pickFile(type: FileType.image);
    if (r?.path == null) return;
    setState(() => _busy = true);
    try {
      final bytes = await ImageProcessing.processCoverAsync(await File(r!.path!).readAsBytes(), maxSize: 800, quality: 88);
      if (mounted) setState(() => _picked = bytes);
    } on Object {
      if (mounted) showSnack(context, 'That picture could not be opened');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final s = context.read<AppServices>();
    final name = _name.text.trim();
    setState(() => _busy = true);
    final existing = widget.existing;
    final id = existing?.id ?? await s.repo.createPlaylist(name.isEmpty ? 'New playlist' : name);
    if (existing != null && name.isNotEmpty && name != existing.name) await s.repo.renamePlaylist(id, name);
    final old = existing?.coverPath;
    if (_picked != null) {
      final dir = Directory('${s.supportDir.path}/playlist_covers')..createSync(recursive: true);
      // A new file name each time, so image caches never show the previous picture.
      final file = File('${dir.path}/p${id}_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await file.writeAsBytes(_picked!);
      await s.repo.setPlaylistCover(id, file.path);
      await deletePlaylistCoverFile(old);
    } else if (_removed && old != null) {
      await s.repo.setPlaylistCover(id, null);
      await deletePlaylistCoverFile(old);
    }
    if (mounted) Navigator.pop(context, id);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final scheme = t.colorScheme;
    final creating = widget.existing == null;
    final Widget picture;
    if (_picked != null) {
      picture = Image.memory(_picked!, fit: BoxFit.cover);
    } else if (_existingPath != null) {
      picture = Image.file(File(_existingPath!), fit: BoxFit.cover);
    } else {
      picture = ColoredBox(
        color: scheme.surfaceContainerHigh,
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.add_photo_alternate_outlined, size: 34, color: scheme.onSurfaceVariant),
          const SizedBox(height: 6),
          Text('Add a photo', style: t.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
        ]),
      );
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(22, 0, 22, 22 + MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Eyebrow(creating ? 'New playlist' : 'Edit playlist'),
          const SizedBox(height: 4),
          Text(creating ? 'Make it yours' : widget.existing!.name, style: t.textTheme.headlineMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 20),
          Center(
            child: Semantics(
              button: true,
              label: _hasPicture ? 'Change picture' : 'Add a picture',
              child: GestureDetector(
                onTap: _busy ? null : _pick,
                child: Stack(children: [
                  ClipRRect(borderRadius: BorderRadius.circular(24), child: SizedBox.square(dimension: 168, child: picture)),
                  if (_busy) const Positioned.fill(child: Loader()),
                  if (_hasPicture)
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: RoundIconButton(tooltip: 'Change picture', icon: Icons.edit_rounded, size: 36, iconSize: 18, glass: true, onPressed: _busy ? null : _pick),
                    ),
                ]),
              ),
            ),
          ),
          if (_hasPicture)
            Center(
              child: TextButton(
                onPressed: _busy ? null : () => setState(() {
                  _picked = null;
                  _removed = true;
                }),
                child: const Text('Remove picture'),
              ),
            )
          else
            const SizedBox(height: 16),
          TextField(
            controller: _name,
            autofocus: creating,
            textCapitalization: TextCapitalization.sentences,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _busy ? null : _save(),
            decoration: const InputDecoration(labelText: 'Name', hintText: 'Late night drives'),
          ),
          const SizedBox(height: 18),
          PillButton(expand: true, height: 52, label: creating ? 'Create playlist' : 'Save', onPressed: _busy ? null : _save),
        ]),
      ),
    );
  }
}

/// Removes a playlist picture from app storage (best effort).
Future<void> deletePlaylistCoverFile(String? path) async {
  if (path == null) return;
  try {
    final f = File(path);
    if (await f.exists()) await f.delete();
  } on Object {
    // already gone or not ours
  }
}
