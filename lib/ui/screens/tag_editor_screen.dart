import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/app_services.dart';
import '../../core/models/track.dart';
import '../../features/metadata/tag_writer.dart';
import '../../platform/bridges.dart';
import '../widgets/common.dart';
import 'identify_screens.dart';

/// Manual tag editor: writes into the file (when possible) and the library.
class TagEditorScreen extends StatefulWidget {
  const TagEditorScreen({super.key, required this.track});
  final Track track;

  @override
  State<TagEditorScreen> createState() => _TagEditorScreenState();
}

class _TagEditorScreenState extends State<TagEditorScreen> {
  late final Map<String, TextEditingController> _c;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final t = widget.track;
    String v(Object? o) => o?.toString() ?? '';
    _c = {
      'title': TextEditingController(text: t.title),
      'artist': TextEditingController(text: v(t.artistName)),
      'album': TextEditingController(text: v(t.albumTitle)),
      'albumArtist': TextEditingController(text: v(t.albumArtist)),
      'trackNo': TextEditingController(text: v(t.trackNo)),
      'discNo': TextEditingController(text: v(t.discNo)),
      'year': TextEditingController(text: v(t.year)),
      'genre': TextEditingController(text: v(t.genre)),
    };
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final s = context.read<AppServices>();
    final t = widget.track;
    setState(() => _saving = true);
    String? txt(String k) {
      final v = _c[k]!.text.trim();
      return v.isEmpty ? null : v;
    }

    final draft = TrackDraft(
      filePath: t.filePath,
      title: txt('title') ?? t.title,
      artist: txt('artist'),
      album: txt('album'),
      albumArtist: txt('albumArtist'),
      trackNo: int.tryParse(_c['trackNo']!.text.trim()),
      discNo: int.tryParse(_c['discNo']!.text.trim()),
      year: int.tryParse(_c['year']!.text.trim()),
      genre: txt('genre'),
      durationMs: t.durationMs,
      bitrate: t.bitrate,
      format: t.format,
      mbRecordingId: t.mbRecordingId,
      mbReleaseId: t.mbReleaseId,
      mbReleaseGroupId: t.mbReleaseGroupId,
      mbArtistId: t.mbArtistId,
      acoustId: t.acoustId,
      isrc: t.isrc,
      replayGainTrack: t.replayGainTrack,
      replayGainAlbum: t.replayGainAlbum,
      hasEmbeddedArt: t.hasEmbeddedArt,
    );
    var outcome = TagWriteOutcome.written;
    try {
      if (s.settings.writeTagsToFiles) {
        final u = TagUpdate({
          'title': draft.title,
          'artist': draft.artist ?? '',
          'album': draft.album ?? '',
          'albumArtist': draft.albumArtist ?? '',
          'trackNo': draft.trackNo?.toString() ?? '',
          'discNo': draft.discNo?.toString() ?? '',
          'date': draft.year?.toString() ?? '',
          'genre': draft.genre ?? '',
        });
        outcome = await s.tagWriter.write(t, u);
      }
      await s.repo.applyTagChanges(t.id, draft);
      if (!mounted) return;
      showSnack(context, outcome == TagWriteOutcome.written ? 'Saved' : 'Saved in the app only (${outcome.name}) - the file itself could not be changed');
      Navigator.pop(context);
    } on PlatformFailure catch (e) {
      if (mounted) showSnack(context, 'Could not save: ${e.message}');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _field(String key, String label, {TextInputType? type}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(controller: _c[key], keyboardType: type, decoration: InputDecoration(labelText: label, border: const OutlineInputBorder())),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit tags'),
        actions: [
          TextButton.icon(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => IdentifyReviewScreen(track: widget.track))),
            icon: const Icon(Icons.auto_fix_high),
            label: const Text('Identify'),
          ),
          TextButton(onPressed: _saving ? null : _save, child: const Text('Save')),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        _field('title', 'Title'),
        _field('artist', 'Artist'),
        _field('album', 'Album'),
        _field('albumArtist', 'Album artist'),
        Row(children: [
          Expanded(child: _field('trackNo', 'Track #', type: TextInputType.number)),
          const SizedBox(width: 12),
          Expanded(child: _field('discNo', 'Disc #', type: TextInputType.number)),
          const SizedBox(width: 12),
          Expanded(child: _field('year', 'Year', type: TextInputType.number)),
        ]),
        _field('genre', 'Genre'),
        if (_saving) const LinearProgressIndicator(),
        const SizedBox(height: 8),
        Text(widget.track.filePath, style: Theme.of(context).textTheme.bodySmall),
      ]),
    );
  }
}
