import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_services.dart';
import '../../core/models/library_models.dart';
import '../../core/models/track.dart';
import '../../features/lyrics/lyrics_clients.dart';
import '../widgets/common.dart';

/// Lyrics options: sync offset, pick another LRCLIB match, edit by hand, Genius page.
Future<void> showLyricsSheet(BuildContext context, Track track) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => Padding(padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom), child: _LyricsSheet(track: track)),
  );
}

class _LyricsSheet extends StatefulWidget {
  const _LyricsSheet({required this.track});
  final Track track;

  @override
  State<_LyricsSheet> createState() => _LyricsSheetState();
}

class _LyricsSheetState extends State<_LyricsSheet> {
  late int _offset = widget.track.lyricsOffsetMs;
  final _query = TextEditingController();
  List<LrclibResult>? _results;
  bool _busy = false;
  String? _error;
  LyricsRow? _row;
  GeniusSong? _genius;

  @override
  void initState() {
    super.initState();
    _query.text = '${widget.track.displayArtist} ${widget.track.title}';
    _load();
  }

  Future<void> _load() async {
    final s = context.read<AppServices>();
    final r = await s.lyrics.cached(widget.track);
    if (mounted) setState(() => _row = r);
  }

  Future<void> _search() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await context.read<AppServices>().lyrics.searchAlternatives(_query.text.trim());
      if (mounted) setState(() => _results = r);
    } on Object catch (e) {
      if (mounted) setState(() => _error = 'Search failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setOffset(int v) async {
    setState(() => _offset = v);
    await context.read<AppServices>().lyrics.setOffset(widget.track, v);
  }

  Future<void> _edit() async {
    final s = context.read<AppServices>();
    final c = TextEditingController(text: _row?.syncedLrc ?? _row?.plainText ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Edit lyrics'),
        content: SizedBox(width: 480, child: TextField(controller: c, maxLines: 14, decoration: const InputDecoration(hintText: 'Plain text, or LRC with [mm:ss.xx] timestamps'))),
        actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Save'))],
      ),
    );
    if (ok == true && c.text.trim().isNotEmpty) {
      final r = await s.lyrics.saveManual(widget.track, c.text);
      if (mounted) setState(() => _row = r);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    final t = Theme.of(context);
    return ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), shrinkWrap: true, children: [
      Text('Lyrics', style: t.textTheme.titleLarge),
      const SizedBox(height: 4),
      Text(_row == null || !_row!.hasAny ? 'None saved' : '${_row!.hasSynced ? 'Synced' : 'Plain text'} · ${_row!.source}', style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      const SizedBox(height: 16),
      Text('Sync offset', style: t.textTheme.titleSmall),
      Row(children: [
        IconButton.filledTonal(tooltip: 'Show earlier', icon: const Icon(Icons.remove), onPressed: () => _setOffset(_offset - 500)),
        Expanded(child: Center(child: Text('${_offset >= 0 ? '+' : ''}${(_offset / 1000).toStringAsFixed(1)} s'))),
        IconButton.filledTonal(tooltip: 'Show later', icon: const Icon(Icons.add), onPressed: () => _setOffset(_offset + 500)),
        TextButton(onPressed: () => _setOffset(0), child: const Text('Reset')),
      ]),
      const Divider(height: 32),
      Text('Find another match (LRCLIB)', style: t.textTheme.titleSmall),
      const SizedBox(height: 8),
      TextField(controller: _query, textInputAction: TextInputAction.search, onSubmitted: (_) => _search(), decoration: InputDecoration(border: const OutlineInputBorder(), suffixIcon: IconButton(icon: const Icon(Icons.search), onPressed: _search))),
      if (_busy) const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator()),
      if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: TextStyle(color: t.colorScheme.error))),
      for (final r in _results ?? const <LrclibResult>[])
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('${r.artistName} - ${r.trackName}', maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('${r.albumName ?? ''}${r.durationSec == null ? '' : ' · ${formatDuration(Duration(seconds: r.durationSec!.round()))}'}${r.hasSynced ? ' · synced' : ''}'),
          onTap: () async {
            final row = await s.lyrics.choose(widget.track, r);
            if (!context.mounted) return;
            setState(() => _row = row);
            showSnack(context, 'Lyrics replaced');
          },
        ),
      const Divider(height: 32),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton.icon(icon: const Icon(Icons.edit_note), label: const Text('Edit by hand'), onPressed: _edit),
        OutlinedButton.icon(
          icon: const Icon(Icons.refresh),
          label: const Text('Fetch again'),
          onPressed: () async {
            setState(() => _busy = true);
            final r = await s.lyrics.lyricsFor(widget.track, refresh: true);
            if (mounted) {
              setState(() {
                _row = r;
                _busy = false;
              });
            }
          },
        ),
        if (_row != null)
          OutlinedButton.icon(
            icon: const Icon(Icons.delete_outline),
            label: const Text('Remove'),
            onPressed: () async {
              await s.repo.deleteLyrics(widget.track.id);
              if (mounted) setState(() => _row = null);
            },
          ),
        if (s.genius.isConfigured)
          OutlinedButton.icon(
            icon: const Icon(Icons.open_in_new),
            label: const Text('View on Genius'),
            onPressed: () async {
              final g = _genius ?? await s.lyrics.geniusInfo(widget.track);
              if (g == null) {
                if (context.mounted) showSnack(context, 'No Genius page found');
                return;
              }
              _genius = g;
              await launchUrl(Uri.parse(g.url), mode: LaunchMode.externalApplication);
            },
          ),
      ]),
      if (_genius?.description != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_genius!.description!, style: t.textTheme.bodySmall)),
    ]);
  }
}
