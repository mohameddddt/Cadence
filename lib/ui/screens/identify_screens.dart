import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/app_services.dart';
import '../../core/models/track.dart';
import '../../features/metadata/identify_service.dart';
import '../../features/metadata/tag_writer.dart';
import '../widgets/common.dart';
import '../widgets/cover_art.dart';

/// Per-track review: current vs proposed tags, confidence, cover preview,
/// Accept / Reject / Pick another (plan 4.5).
class IdentifyReviewScreen extends StatefulWidget {
  const IdentifyReviewScreen({super.key, required this.track, this.onDone});
  final Track track;
  final VoidCallback? onDone;

  @override
  State<IdentifyReviewScreen> createState() => _IdentifyReviewScreenState();
}

class _IdentifyReviewScreenState extends State<IdentifyReviewScreen> {
  IdentifyResult? _result;
  List<IdentifyCandidate> _candidates = [];
  int _selected = 0;
  String _stage = 'Starting…';
  bool _busy = true;
  String? _error;
  final _title = TextEditingController();
  final _artist = TextEditingController();

  @override
  void initState() {
    super.initState();
    _title.text = widget.track.title;
    _artist.text = widget.track.artistName ?? '';
    _run();
  }

  @override
  void dispose() {
    _title.dispose();
    _artist.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final s = context.read<AppServices>();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await s.identify.identify(widget.track, onStage: (st) {
        if (mounted) setState(() => _stage = st);
      });
      if (!mounted) return;
      setState(() {
        _result = r;
        _candidates = r.candidates;
        _selected = 0;
      });
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _manual() async {
    final s = context.read<AppServices>();
    setState(() => _busy = true);
    try {
      final c = await s.identify.searchManual(widget.track, title: _title.text.trim(), artist: _artist.text.trim().isEmpty ? null : _artist.text.trim());
      if (mounted) {
        setState(() {
          _candidates = c;
          _selected = 0;
        });
      }
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _accept() async {
    final s = context.read<AppServices>();
    final c = _candidates[_selected];
    setState(() => _busy = true);
    final outcome = await s.identify.apply(widget.track, c);
    // fetch the cover for the newly known release in the background
    final t = await s.repo.trackById(widget.track.id);
    if (t?.albumId != null) {
      final album = await s.repo.albumById(t!.albumId!);
      if (album != null) unawaited(s.covers.ensureAlbumCover(album, force: true).then((_) => s.coverCache.retry(album.id)));
    }
    if (!mounted) return;
    showSnack(context, outcome == TagWriteOutcome.written ? 'Tags updated' : 'Saved in the app (${outcome.name}) - the file could not be changed');
    widget.onDone?.call();
    Navigator.pop(context, true);
  }

  Future<void> _reject() async {
    await context.read<AppServices>().identify.skip(widget.track);
    if (!mounted) return;
    widget.onDone?.call();
    Navigator.pop(context, false);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cur = widget.track;
    return Scaffold(
      appBar: AppBar(title: const Text('Identify song')),
      body: _busy
          ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [const CircularProgressIndicator(), const SizedBox(height: 16), Text(_stage)]))
          : ListView(padding: const EdgeInsets.all(16), children: [
              ListTile(contentPadding: EdgeInsets.zero, leading: CoverArt(track: cur, size: 56), title: Text(cur.title), subtitle: Text('${cur.displayArtist} · ${cur.displayAlbum}')),
              if (_error != null) Text(_error!, style: TextStyle(color: t.colorScheme.error)),
              for (final n in _result?.notes ?? const <String>[])
                Padding(padding: const EdgeInsets.only(bottom: 6), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [const Icon(Icons.info_outline, size: 16), const SizedBox(width: 8), Expanded(child: Text(n, style: t.textTheme.bodySmall))])),
              if (_candidates.isEmpty) ...[
                const SizedBox(height: 8),
                const Text('No match found. Try searching by hand:'),
              ] else ...[
                Text('Matches', style: t.textTheme.titleMedium),
                const SizedBox(height: 8),
                for (var i = 0; i < _candidates.length; i++) _CandidateTile(candidate: _candidates[i], selected: i == _selected, onTap: () => setState(() => _selected = i)),
                const SizedBox(height: 16),
                _Comparison(current: cur, candidate: _candidates[_selected]),
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(child: FilledButton.icon(onPressed: _accept, icon: const Icon(Icons.check), label: const Text('Accept'))),
                  const SizedBox(width: 12),
                  Expanded(child: OutlinedButton.icon(onPressed: _reject, icon: const Icon(Icons.close), label: const Text('Reject'))),
                ]),
              ],
              const Divider(height: 32),
              Text('Search by hand', style: t.textTheme.titleSmall),
              const SizedBox(height: 8),
              TextField(controller: _title, decoration: const InputDecoration(labelText: 'Title', border: OutlineInputBorder())),
              const SizedBox(height: 8),
              TextField(controller: _artist, decoration: const InputDecoration(labelText: 'Artist', border: OutlineInputBorder())),
              const SizedBox(height: 8),
              Row(children: [
                FilledButton.tonalIcon(onPressed: _manual, icon: const Icon(Icons.search), label: const Text('Search MusicBrainz')),
                const SizedBox(width: 8),
                TextButton(onPressed: _run, child: const Text('Run again')),
              ]),
            ]),
    );
  }
}

class _CandidateTile extends StatelessWidget {
  const _CandidateTile({required this.candidate, required this.selected, required this.onTap});
  final IdentifyCandidate candidate;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final pct = (candidate.confidence * 100).round();
    final color = pct >= 90 ? Colors.green : pct >= 70 ? Colors.orange : t.colorScheme.error;
    return Card(
      color: selected ? t.colorScheme.secondaryContainer : null,
      child: ListTile(
        onTap: onTap,
        selected: selected,
        leading: CircleAvatar(backgroundColor: color.withValues(alpha: 0.18), child: Text('$pct%', style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w700))),
        title: Text(candidate.recording.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text('${candidate.recording.artistCredit}${candidate.release == null ? '' : ' · ${candidate.release!.title}'}${candidate.release?.year == null ? '' : ' (${candidate.release!.year})'}', maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: Text(candidate.origin, style: t.textTheme.labelSmall),
      ),
    );
  }
}

class _Comparison extends StatelessWidget {
  const _Comparison({required this.current, required this.candidate});
  final Track current;
  final IdentifyCandidate candidate;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final p = candidate.proposed.toDisplayMap();
    final cur = <String, String?>{
      'Title': current.title,
      'Artist': current.artistName,
      'Album': current.albumTitle,
      'Album artist': current.albumArtist,
      'Track': current.trackNo?.toString(),
      'Disc': current.discNo?.toString(),
      'Year': current.year?.toString(),
      'Genre': current.genre,
      'ISRC': current.isrc,
      'Label': null,
    };
    final rid = candidate.release?.id;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          if (rid != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                ClipRRect(borderRadius: BorderRadius.circular(8), child: SizedBox(width: 96, height: 96, child: Image.network('https://coverartarchive.org/release/$rid/front-250', fit: BoxFit.cover, errorBuilder: (_, _, _) => const ColoredBox(color: Colors.black12, child: Icon(Icons.image_not_supported_outlined))))),
              ]),
            ),
          Row(children: [
            const SizedBox(width: 90),
            Expanded(child: Text('Current', style: t.textTheme.labelMedium)),
            Expanded(child: Text('Proposed', style: t.textTheme.labelMedium)),
          ]),
          const Divider(),
          for (final e in p.entries)
            if (e.value != null || cur[e.key] != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(width: 90, child: Text(e.key, style: t.textTheme.bodySmall)),
                  Expanded(child: Text(cur[e.key] ?? '—', style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant))),
                  Expanded(child: Text(e.value ?? '—', style: t.textTheme.bodyMedium?.copyWith(fontWeight: e.value != cur[e.key] ? FontWeight.w700 : null, color: e.value != cur[e.key] ? t.colorScheme.primary : null))),
                ]),
              ),
        ]),
      ),
    );
  }
}

/// The review queue plus "Identify all unmatched tracks" with progress (plan 4.5).
class FixTagsScreen extends StatefulWidget {
  const FixTagsScreen({super.key, this.initial});

  /// Restrict the batch to these tracks (an album); null = whole library.
  final List<Track>? initial;

  @override
  State<FixTagsScreen> createState() => _FixTagsScreenState();
}

class _FixTagsScreenState extends State<FixTagsScreen> {
  BatchIdentifyProgress? _progress;
  bool _cancel = false;
  StreamSubscription<BatchIdentifyProgress>? _sub;

  @override
  void dispose() {
    _cancel = true;
    _sub?.cancel();
    super.dispose();
  }

  void _start(List<Track> tracks) {
    final s = context.read<AppServices>();
    setState(() {
      _cancel = false;
      _progress = BatchIdentifyProgress(0, tracks.length, 0, 0, 0);
    });
    _sub = s.identify.identifyAll(tracks: tracks, isCancelled: () => _cancel).listen((p) {
      if (mounted) setState(() => _progress = p);
    }, onDone: () {
      if (mounted) showSnack(context, 'Done: ${_progress?.matched ?? 0} matched, ${_progress?.needsReview ?? 0} to review');
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    final t = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Fix tags')),
      body: StreamBuilder<List<Track>>(
        stream: s.db.watch(() async {
          final base = widget.initial ?? await s.repo.tracks();
          return base.where((x) => x.identifyState != IdentifyState.matched && x.identifyState != IdentifyState.skipped || x.identifyState == IdentifyState.needsReview).toList();
        }),
        builder: (context, snap) {
          final list = snap.data ?? const <Track>[];
          final review = list.where((x) => x.identifyState == IdentifyState.needsReview).toList();
          final unmatched = list.where((x) => x.identifyState == IdentifyState.unmatched).toList();
          return ListView(children: [
            if (!s.identify.acoustId.isConfigured)
              MaterialBanner(content: const Text('Add an AcoustID key in Settings > Accounts for fingerprint matching. Without it only title search is used.'), actions: const [SizedBox.shrink()]),
            Padding(
              padding: const EdgeInsets.all(16),
              child: _progress != null && !_progress!.finished
                  ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Identifying ${_progress!.done + 1} of ${_progress!.total}${_progress!.current == null ? '' : ' — ${_progress!.current!.title}'}'),
                      const SizedBox(height: 8),
                      LinearProgressIndicator(value: _progress!.total == 0 ? null : _progress!.done / _progress!.total),
                      Text('${_progress!.matched} matched · ${_progress!.needsReview} to review · ${_progress!.failed} failed', style: t.textTheme.bodySmall),
                      TextButton(onPressed: () => setState(() => _cancel = true), child: const Text('Stop')),
                    ])
                  : FilledButton.icon(onPressed: unmatched.isEmpty ? null : () => _start(unmatched), icon: const Icon(Icons.auto_fix_high), label: Text('Identify all unmatched (${unmatched.length})')),
            ),
            if (review.isNotEmpty) SectionHeader('Needs your review (${review.length})'),
            for (final tr in review) _row(context, tr),
            if (unmatched.isNotEmpty) SectionHeader('Unmatched (${unmatched.length})'),
            for (final tr in unmatched.take(200)) _row(context, tr),
            if (list.isEmpty) const Padding(padding: EdgeInsets.all(48), child: EmptyState(icon: Icons.check_circle_outline, title: 'Everything is tagged')),
          ]);
        },
      ),
    );
  }

  Widget _row(BuildContext context, Track tr) => ListTile(
        leading: CoverArt(track: tr, size: 44),
        title: Text(tr.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text('${tr.displayArtist} · ${tr.displayAlbum}', maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => IdentifyReviewScreen(track: tr))),
      );
}
