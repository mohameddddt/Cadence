import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/app_services.dart';
import '../../core/models/library_models.dart';
import '../../core/models/track.dart';
import '../../features/downloader/source_detect.dart';
import '../../features/sources/source_provider.dart';
import '../../features/sources/unified_search.dart';
import '../widgets/common.dart';
import '../widgets/cover_art.dart';
import '../widgets/kit.dart';
import '../widgets/track_widgets.dart';
import 'album_screen.dart';
import 'artist_screen.dart';
import 'downloads_screen.dart';
import 'search_explore.dart';

/// Queue a remote result and tell the user what happened (new / duplicate / already queued).
Future<void> downloadRemote(BuildContext context, RemoteTrack t) async {
  final s = context.read<AppServices>();
  try {
    final r = await s.downloads.enqueueRemote(t);
    if (!context.mounted) return;
    if (r.duplicate != null) {
      showSnack(context, 'Already in your library', action: SnackBarAction(label: 'Download anyway', onPressed: () => s.downloads.enqueueRemote(t, force: true)));
    } else if (r.alreadyQueued) {
      showSnack(context, 'Already in the download queue');
    } else {
      showSnack(context, 'Download started: ${t.title}');
    }
  } on Object catch (e) {
    if (context.mounted) showSnack(context, 'Could not start download: $e');
  }
}

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, this.initialQuery});
  final String? initialQuery;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  StreamSubscription<List<SearchSection>>? _sub;
  List<SearchSection> _sections = const [];
  RemoteTrack? _linked;
  String? _linkError;
  bool _resolving = false;
  final Set<String> _providerFilter = {};
  String _query = '';

  @override
  void initState() {
    super.initState();
    if (widget.initialQuery != null) {
      _controller.text = widget.initialQuery!;
      WidgetsBinding.instance.addPostFrameCallback((_) => _run());
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _sub?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _run);
  }

  Future<void> _run() async {
    final s = context.read<AppServices>();
    final text = _controller.text.trim();
    _sub?.cancel();
    setState(() {
      _query = text;
      _linked = null;
      _linkError = null;
    });
    if (text.isEmpty) {
      setState(() => _sections = const []);
      return;
    }
    final url = extractUrl(text);
    if (url != null) {
      await _resolveLink(url);
      return;
    }
    if (text.length >= 2) s.settings.addRecentSearch(text);
    _sub = s.search.search(text, onlyProviders: _providerFilter.isEmpty ? null : _providerFilter).listen((v) {
      if (mounted) setState(() => _sections = v);
    });
  }

  Future<void> _resolveLink(String url) async {
    final s = context.read<AppServices>();
    setState(() {
      _resolving = true;
      _sections = const [];
    });
    try {
      final info = detectSource(url);
      final provider = s.sources.forUrl(info) ?? s.sources.byId('ytdlp-other');
      RemoteTrack? r;
      if (provider != null) r = await provider.resolve(url);
      if (mounted) {
        setState(() {
          _linked = r;
          _linkError = r == null ? 'Could not read this link.' : null;
        });
      }
    } on Object catch (e) {
      if (mounted) setState(() => _linkError = '$e');
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  void _searchFor(String q) {
    _controller.text = q;
    _controller.selection = TextSelection.collapsed(offset: q.length);
    _run();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // A bright bar on the dark page (and an ink one on a light page).
    final fieldText = scheme.surface;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 12),
            child: Row(children: [
              Expanded(child: Text('Search', style: Theme.of(context).textTheme.displaySmall)),
              IconButton(tooltip: 'Paste a link', icon: const Icon(Icons.add_link_rounded), onPressed: () => showAddLinkDialog(context)),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(
              height: 48,
              decoration: BoxDecoration(color: scheme.onSurface, borderRadius: BorderRadius.circular(8)),
              child: Row(children: [
                Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Icon(Icons.search_rounded, color: fieldText, size: 26)),
                Expanded(
                  child: TextField(
                    controller: _controller,
                    textInputAction: TextInputAction.search,
                    onChanged: _onChanged,
                    onSubmitted: (_) => _run(),
                    cursorColor: fieldText,
                    style: TextStyle(color: fieldText, fontWeight: FontWeight.w600, fontSize: 15),
                    decoration: InputDecoration(
                      filled: false,
                      isCollapsed: true,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      hintText: 'Songs, artists or a link',
                      hintStyle: TextStyle(color: fieldText.withValues(alpha: 0.6), fontWeight: FontWeight.w600, fontSize: 15),
                    ),
                  ),
                ),
                if (_controller.text.isNotEmpty)
                  IconButton(
                    tooltip: 'Clear',
                    icon: Icon(Icons.close_rounded, color: fieldText),
                    onPressed: () {
                      _controller.clear();
                      _run();
                    },
                  ),
              ]),
            ),
          ),
          Expanded(child: _body(context)),
        ]),
      ),
    );
  }

  /// Online-source filters, shown with results.
  Widget _providerChips(BuildContext context) {
    final s = context.read<AppServices>();
    final providers = s.sources.enabled.where((p) => p.supportsSearch).toList();
    return SizedBox(
      height: 52,
      child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), children: [
        for (final p in providers)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: PillChip(
              label: p.label,
              selected: _providerFilter.contains(p.id),
              onTap: () {
                final on = !_providerFilter.contains(p.id);
                setState(() => on ? _providerFilter.add(p.id) : _providerFilter.remove(p.id));
                if (_query.isNotEmpty) _run();
              },
            ),
          ),
      ]),
    );
  }

  Widget _body(BuildContext context) {
    if (_resolving) return const Center(child: CircularProgressIndicator());
    if (_linkError != null) return EmptyState(icon: Icons.link_off, title: 'Link not supported', message: _linkError);
    if (_linked != null) {
      return ListView(padding: EdgeInsets.only(bottom: bottomClearance(context)), children: [const SectionHeader('Link'), RemoteTile(track: _linked!)]);
    }
    if (_query.isEmpty) return SearchExplore(onSearch: _searchFor);
    if (_sections.isEmpty) return const Center(child: CircularProgressIndicator());
    return ListView(padding: EdgeInsets.only(bottom: bottomClearance(context)), children: [
      _providerChips(context),
      for (final sec in _sections) ..._section(context, sec),
    ]);
  }

  List<Widget> _section(BuildContext context, SearchSection sec) {
    final s = context.read<AppServices>();
    final out = <Widget>[
      SectionHeader(sec.label, trailing: sec.status == SectionStatus.loading ? const Padding(padding: EdgeInsets.only(right: 12), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))) : null),
    ];
    if (sec.status == SectionStatus.failed) {
      out.add(ListTile(leading: const Icon(Icons.error_outline), title: Text(sec.error ?? 'Failed'), dense: true));
      return out;
    }
    if (sec.id == 'local') {
      if (sec.artists.isNotEmpty) {
        out.add(SizedBox(
          height: 96,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
            for (final a in sec.artists)
              InkWell(
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ArtistScreen(artistId: a.id))),
                child: SizedBox(width: 80, child: Column(children: [CoverArt(artistId: a.id, seed: a.name, size: 56, circle: true), const SizedBox(height: 4), Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.labelSmall)])),
              ),
          ]),
        ));
      }
      for (final a in sec.albums) {
        out.add(ListTile(leading: CoverArt(albumId: a.id, seed: a.title, size: 44), title: Text(a.title), subtitle: Text(a.displayArtist), onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AlbumScreen(albumId: a.id)))));
      }
      for (var i = 0; i < sec.tracks.length; i++) {
        out.add(TrackTile(track: sec.tracks[i], onTap: () => s.player.playTracks(sec.tracks, index: i)));
      }
      if (sec.isEmpty) out.add(const ListTile(dense: true, title: Text('Nothing on this device')));
      return out;
    }
    for (final r in sec.remote) {
      out.add(RemoteTile(track: r));
    }
    if (sec.status == SectionStatus.done && sec.remote.isEmpty) out.add(const ListTile(dense: true, title: Text('No results')));
    return out;
  }
}

/// A remote result: play (stream), download, or open a collection.
class RemoteTile extends StatelessWidget {
  const RemoteTile({super.key, required this.track});
  final RemoteTrack track;

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    final t = Theme.of(context);
    final sub = [
      if (track.artist != null) track.artist!,
      if (track.durationSec != null) formatDuration(Duration(seconds: track.durationSec!)),
      track.source.label,
      if (track.format != null) track.format!,
    ].join(' · ');
    return ListTile(
      leading: track.isCollection
          ? const CircleAvatar(child: Icon(Icons.folder_open))
          : CoverArt(url: track.thumbnail, seed: track.title, size: 48),
      title: Text(track.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: track.isCollection ? () => showCollectionSheet(context, track) : null,
      trailing: track.isCollection
          ? const Icon(Icons.chevron_right)
          : Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                tooltip: 'Stream',
                icon: const Icon(Icons.play_circle_outline),
                onPressed: () async {
                  try {
                    showSnack(context, 'Loading stream…', duration: const Duration(seconds: 2));
                    await s.player.playRemote(track);
                  } on Object catch (e) {
                    if (context.mounted) showSnack(context, 'Cannot stream: $e');
                  }
                },
              ),
              IconButton(tooltip: 'Download', icon: Icon(Icons.download, color: t.colorScheme.primary), onPressed: () => downloadRemote(context, track)),
            ]),
      onLongPress: track.isCollection ? null : () => s.player.enqueueRemote(track).then((_) {
            if (context.mounted) showSnack(context, 'Added to queue');
          }),
    );
  }
}

Future<void> showCollectionSheet(BuildContext context, RemoteTrack collection) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _CollectionSheet(collection: collection),
  );
}

class _CollectionSheet extends StatefulWidget {
  const _CollectionSheet({required this.collection});
  final RemoteTrack collection;

  @override
  State<_CollectionSheet> createState() => _CollectionSheetState();
}

class _CollectionSheetState extends State<_CollectionSheet> {
  List<RemoteTrack>? _items;
  final Set<int> _selected = {};
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = context.read<AppServices>();
    try {
      final provider = s.sources.byId(widget.collection.provider) ?? s.sources.byId('ytdlp-other')!;
      final items = await provider.expand(widget.collection);
      if (mounted) {
        setState(() {
          _items = items;
          _selected.addAll(List.generate(items.length, (i) => i));
        });
      }
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    final items = _items;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (context, scroll) => Column(children: [
        ListTile(title: Text(widget.collection.title, maxLines: 2), subtitle: Text(widget.collection.artist ?? widget.collection.source.label)),
        if (_error != null) Padding(padding: const EdgeInsets.all(16), child: Text(_error!))
        else if (items == null) const Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator())
        else ...[
          Row(children: [
            const SizedBox(width: 8),
            TextButton(onPressed: () => setState(() => _selected.length == items.length ? _selected.clear() : _selected.addAll(List.generate(items.length, (i) => i))), child: Text(_selected.length == items.length ? 'Select none' : 'Select all')),
            const Spacer(),
            Text('${_selected.length} of ${items.length}'),
            const SizedBox(width: 12),
          ]),
          Expanded(
            child: ListView.builder(
              controller: scroll,
              itemCount: items.length,
              itemBuilder: (context, i) => CheckboxListTile(
                value: _selected.contains(i),
                onChanged: (v) => setState(() => v == true ? _selected.add(i) : _selected.remove(i)),
                title: Text(items[i].title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text([if (items[i].durationSec != null) formatDuration(Duration(seconds: items[i].durationSec!)), if (items[i].format != null) items[i].format!].join(' · ')),
                secondary: IconButton(icon: const Icon(Icons.play_arrow), onPressed: () => s.player.playRemote(items[i])),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: FilledButton.icon(
                icon: const Icon(Icons.download),
                label: Text('Download ${_selected.length} ${_selected.length == 1 ? 'track' : 'tracks'}'),
                onPressed: _selected.isEmpty ? null : () async {
                  final chosen = [for (final i in _selected.toList()..sort()) items[i]];
                  final r = await s.downloads.enqueueMany(chosen);
                  if (!context.mounted) return;
                  Navigator.pop(context);
                  final fresh = r.where((e) => e.isNew).length;
                  showSnack(context, '$fresh queued${fresh < r.length ? ', ${r.length - fresh} skipped (already have / queued)' : ''}');
                },
              ),
            ),
          ),
        ],
      ]),
    );
  }
}

/// Small reusable download-status chip for a job.
class JobStatusChip extends StatelessWidget {
  const JobStatusChip({super.key, required this.job});
  final DownloadJob job;

  @override
  Widget build(BuildContext context) {
    final (label, icon) = switch (job.status) {
      JobStatus.queued => ('Queued', Icons.schedule),
      JobStatus.running => ('Downloading', Icons.downloading),
      JobStatus.postprocessing => ('Processing', Icons.auto_fix_high),
      JobStatus.done => ('Done', Icons.check_circle),
      JobStatus.failed => ('Failed', Icons.error),
      JobStatus.cancelled => ('Cancelled', Icons.cancel),
    };
    return Chip(avatar: Icon(icon, size: 16), label: Text(label), visualDensity: VisualDensity.compact);
  }
}

/// Keeps Track import referenced for callers that pass Track lists.
typedef TrackList = List<Track>;
