import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/app_services.dart';
import '../../core/models/library_models.dart';
import '../../features/downloader/source_detect.dart';
import '../widgets/common.dart';
import '../widgets/cover_art.dart';
import 'search_screen.dart';

/// Active / queued / finished / failed downloads with retry, cancel and logs (plan phase 8).
class DownloadsScreen extends StatelessWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Downloads'),
        actions: [
          IconButton(tooltip: 'Add link', icon: const Icon(Icons.add_link), onPressed: () => showAddLinkDialog(context)),
          PopupMenuButton<String>(
            onSelected: (v) async {
              switch (v) {
                case 'retry':
                  await s.downloads.retryAllFailed();
                case 'clear':
                  await s.downloads.clearFinished();
                case 'update':
                  await _update(context);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'retry', child: Text('Retry all failed')),
              PopupMenuItem(value: 'clear', child: Text('Clear finished')),
              PopupMenuItem(value: 'update', child: Text('Update yt-dlp')),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(onPressed: () => showAddLinkDialog(context), icon: const Icon(Icons.add_link), label: const Text('Add link')),
      body: StreamBuilder<List<DownloadJob>>(
        stream: s.jobs.watchAll(),
        builder: (context, snap) {
          final jobs = snap.data;
          if (jobs == null) return const Center(child: CircularProgressIndicator());
          if (jobs.isEmpty) {
            return const EmptyState(icon: Icons.download_for_offline_outlined, title: 'No downloads yet', message: 'Paste a link, share one from YouTube / SoundCloud / your browser, or use the Search tab.');
          }
          final active = jobs.where((j) => j.status == JobStatus.running || j.status == JobStatus.postprocessing).toList();
          final queued = jobs.where((j) => j.status == JobStatus.queued).toList();
          final failed = jobs.where((j) => j.status == JobStatus.failed).toList();
          final done = jobs.where((j) => j.status == JobStatus.done || j.status == JobStatus.cancelled).toList();
          return ListenableBuilder(
            listenable: s.downloads,
            builder: (context, _) => ListView(padding: const EdgeInsets.only(bottom: 120), children: [
              _EngineBanner(),
              if (active.isNotEmpty) ...[const SectionHeader('Active'), for (final j in active) _JobCard(job: j)],
              if (queued.isNotEmpty) ...[SectionHeader('Queued (${queued.length})'), for (final j in queued) _JobCard(job: j)],
              if (failed.isNotEmpty) ...[SectionHeader('Failed (${failed.length})'), for (final j in failed) _JobCard(job: j)],
              if (done.isNotEmpty) ...[SectionHeader('Finished (${done.length})'), for (final j in done) _JobCard(job: j)],
            ]),
          );
        },
      ),
    );
  }

  Future<void> _update(BuildContext context) async {
    final s = context.read<AppServices>();
    showSnack(context, 'Updating yt-dlp…');
    try {
      final r = await s.engines.current.update(s.settings.ytDlpChannel);
      await s.settings.setLastYtDlpUpdate(DateTime.now());
      if (context.mounted) showSnack(context, 'yt-dlp: $r');
    } on Object catch (e) {
      if (context.mounted) showSnack(context, 'Update failed: $e');
    }
  }
}

/// "yt-dlp 2026.08.19" / "2026.08.19" -> "2026.08.19"; null when there is nothing to show.
String? _ytDlpVersion(String? raw) {
  final v = raw?.replaceFirst(RegExp(r'^yt-dlp\s*', caseSensitive: false), '').trim();
  return (v == null || v.isEmpty) ? null : v;
}

class _EngineBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppServices>();
    final engine = s.engines.current;
    return FutureBuilder<String?>(
      future: engine.version().catchError((Object _) => null),
      builder: (context, snap) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Wrap(spacing: 8, children: [
          Chip(avatar: const Icon(Icons.memory, size: 16), label: Text(engine.label), visualDensity: VisualDensity.compact),
          // The on-device library reports "yt-dlp 2026.08.19", the server just the number.
          if (_ytDlpVersion(snap.data) case final v?) Chip(label: Text('yt-dlp $v'), visualDensity: VisualDensity.compact),
          if (s.settings.wifiOnly) const Chip(avatar: Icon(Icons.wifi, size: 16), label: Text('Wi-Fi only'), visualDensity: VisualDensity.compact),
        ]),
      ),
    );
  }
}

class _JobCard extends StatelessWidget {
  const _JobCard({required this.job});
  final DownloadJob job;

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    final t = Theme.of(context);
    final progress = job.status == JobStatus.running ? (s.downloads.progressOf(job.id) > 0 ? s.downloads.progressOf(job.id) : job.progress) : job.progress;
    final title = job.title ?? Uri.tryParse(job.url)?.host ?? job.url;
    final done = job.status == JobStatus.done && job.trackId != null;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            CoverArt(url: job.thumbnail, seed: title, size: 44),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.textTheme.titleSmall),
                Text([if (job.artist != null) job.artist!, detectSource(job.url).source.label].join(' · '), style: t.textTheme.bodySmall),
              ]),
            ),
            JobStatusChip(job: job),
          ]),
          if (job.status == JobStatus.running || job.status == JobStatus.postprocessing) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(value: job.status == JobStatus.postprocessing || progress <= 0 ? null : progress / 100),
            const SizedBox(height: 4),
            Text('${job.stage ?? ''}${job.status == JobStatus.running && progress > 0 ? ' · ${progress.toStringAsFixed(0)}%' : ''}', style: t.textTheme.bodySmall),
          ],
          if (job.status == JobStatus.queued && job.stage != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(job.stage!, style: t.textTheme.bodySmall)),
          if (job.status == JobStatus.failed && job.error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(job.error!, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error))),
          if (done && job.stage == 'Already in library') Padding(padding: const EdgeInsets.only(top: 6), child: Text('Already in your library', style: t.textTheme.bodySmall)),
          Align(
            alignment: Alignment.centerRight,
            child: Wrap(spacing: 4, children: [
              if (job.status == JobStatus.failed || job.status == JobStatus.cancelled) TextButton.icon(onPressed: () => s.downloads.retry(job.id), icon: const Icon(Icons.refresh), label: const Text('Retry')),
              if (job.status.isActive) TextButton.icon(onPressed: () => s.downloads.cancel(job.id), icon: const Icon(Icons.close), label: const Text('Cancel')),
              if (done)
                TextButton.icon(
                  onPressed: () async {
                    final tr = await s.repo.trackById(job.trackId!);
                    if (tr != null) await s.player.playTracks([tr]);
                  },
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Play'),
                ),
              if (job.log != null && job.log!.isNotEmpty) TextButton.icon(onPressed: () => _showLog(context, job), icon: const Icon(Icons.article_outlined), label: const Text('Log')),
              if (!job.status.isActive) IconButton(tooltip: 'Remove', icon: const Icon(Icons.delete_outline), onPressed: () => s.downloads.remove(job.id)),
            ]),
          ),
        ]),
      ),
    );
  }

  void _showLog(BuildContext context, DownloadJob job) {
    showDialog<void>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Log'),
        content: SizedBox(width: 500, height: 360, child: SingleChildScrollView(child: SelectableText(job.log ?? '', style: const TextStyle(fontFamily: 'monospace', fontSize: 11)))),
        actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('Close'))],
      ),
    );
  }
}

/// Paste-a-link dialog. Detects the source, expands playlists into a picker.
Future<void> showAddLinkDialog(BuildContext context, {String? initial}) async {
  final c = TextEditingController(text: initial);
  final s = context.read<AppServices>();
  final go = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      title: const Text('Add a link'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: c, autofocus: true, minLines: 1, maxLines: 3, decoration: const InputDecoration(hintText: 'https://…  (YouTube, SoundCloud, Bandcamp, Internet Archive…)', border: OutlineInputBorder()), onSubmitted: (_) => Navigator.pop(d, true)),
        const SizedBox(height: 8),
        const Text('Only download what you have the right to: your own uploads, Creative Commons / public domain music, or things you bought.', style: TextStyle(fontSize: 12)),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Continue'))],
    ),
  );
  if (go != true || !context.mounted) return;
  final url = extractUrl(c.text) ?? c.text.trim();
  if (url.isEmpty) return;
  final info = detectSource(url);
  if (!info.supportedByYtDlp && s.sources.forUrl(info) == null) {
    showSnack(context, 'This link is not supported');
    return;
  }
  try {
    final provider = s.sources.forUrl(info) ?? s.sources.byId('ytdlp-other')!;
    showSnack(context, 'Reading link…', duration: const Duration(seconds: 2));
    debugPrint('addLink: resolving $url via ${provider.id}');
    final r = await provider.resolve(url);
    debugPrint('addLink: resolved ${r?.title} collection=${r?.isCollection}');
    if (!context.mounted) return;
    if (r == null) {
      // Unknown to resolve(): still let yt-dlp try the URL directly.
      await s.downloads.enqueueUrl(url);
      if (context.mounted) showSnack(context, 'Queued');
    } else if (r.isCollection) {
      await showCollectionSheet(context, r);
    } else {
      await downloadRemote(context, r);
    }
  } on Object catch (e, st) {
    debugPrint('addLink failed: $e $st');
    if (context.mounted) showSnack(context, 'Could not read the link: $e', duration: const Duration(seconds: 10));
  }
}
