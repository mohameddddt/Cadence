import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart' show AndroidEqualizerParameters;
import 'package:provider/provider.dart';

import '../../app/app_services.dart';
import '../../app/theme.dart';
import '../../core/models/library_models.dart';
import '../../core/models/track.dart';
import '../../features/playback/media_items.dart';
import '../../features/playback/sleep_timer.dart';
import '../widgets/common.dart';
import '../widgets/cover_art.dart';
import '../widgets/lyrics_view.dart';
import '../widgets/seek_bar.dart';
import '../widgets/track_widgets.dart';
import 'album_screen.dart';
import 'artist_screen.dart';
import 'identify_screens.dart';
import 'lyrics_sheet.dart';

Future<void> openNowPlaying(BuildContext context) {
  return Navigator.of(context, rootNavigator: true).push(PageRouteBuilder<void>(
    pageBuilder: (_, _, _) => const NowPlayingScreen(),
    transitionsBuilder: (_, a, _, child) => SlideTransition(position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)), child: child),
    transitionDuration: const Duration(milliseconds: 320),
  ));
}

class NowPlayingScreen extends StatefulWidget {
  const NowPlayingScreen({super.key});

  @override
  State<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends State<NowPlayingScreen> {
  bool _showLyrics = false;
  String? _schemeFor;
  ColorScheme? _scheme;

  Future<void> _updateScheme(String? coverPath, Brightness brightness) async {
    if (coverPath == _schemeFor) return;
    _schemeFor = coverPath;
    if (coverPath == null || !File(coverPath).existsSync()) {
      if (mounted) setState(() => _scheme = null);
      return;
    }
    try {
      final s = await AppTheme.fromCover(ResizeImage(FileImage(File(coverPath)), width: 96), brightness);
      if (mounted && _schemeFor == coverPath) setState(() => _scheme = s);
    } on Object {
      // keep the app colours
    }
  }

  @override
  Widget build(BuildContext context) {
    final services = context.read<AppServices>();
    final player = services.player;
    final base = Theme.of(context);
    final useCover = services.settings.coverColors;
    return StreamBuilder<MediaItem?>(
      stream: player.currentItem,
      builder: (context, snap) {
        final item = snap.data;
        if (item == null) return Scaffold(appBar: AppBar(), body: const EmptyState(icon: Icons.music_off, title: 'Nothing is playing'));
        final coverPath = services.coverCache.albumCover(item.albumId) ?? (item.artUri?.scheme == 'file' ? item.artUri!.toFilePath() : null);
        if (useCover) _updateScheme(coverPath, base.brightness);
        final theme = useCover && _scheme != null ? base.copyWith(colorScheme: _scheme, scaffoldBackgroundColor: _scheme!.surface) : base;
        final scheme = theme.colorScheme;
        return Theme(
          data: theme,
          child: GestureDetector(
            onVerticalDragEnd: (d) {
              if ((d.primaryVelocity ?? 0) > 700) Navigator.of(context).maybePop();
            },
            child: Scaffold(
              backgroundColor: scheme.surface,
              appBar: AppBar(
                backgroundColor: Colors.transparent,
                leading: IconButton(tooltip: 'Close', icon: const Icon(Icons.keyboard_arrow_down, size: 32), onPressed: () => Navigator.of(context).maybePop()),
                title: Text(item.album ?? 'Now playing', style: theme.textTheme.titleSmall),
                centerTitle: true,
                actions: [
                  IconButton(tooltip: 'More', icon: const Icon(Icons.more_vert), onPressed: () => _moreMenu(context, item)),
                ],
              ),
              body: SafeArea(
                child: LayoutBuilder(builder: (context, c) {
                  final wide = c.maxWidth > 700;
                  final art = _artOrLyrics(context, item, scheme, coverPath);
                  final controls = _controls(context, item, scheme);
                  if (wide) {
                    return Row(children: [
                      Expanded(child: Padding(padding: const EdgeInsets.all(24), child: art)),
                      Expanded(child: Padding(padding: const EdgeInsets.all(24), child: controls)),
                    ]);
                  }
                  return Column(children: [
                    Expanded(child: Padding(padding: const EdgeInsets.fromLTRB(24, 8, 24, 8), child: art)),
                    Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 12), child: controls),
                  ]);
                }),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _artOrLyrics(BuildContext context, MediaItem item, ColorScheme scheme, String? coverPath) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: _showLyrics
          ? _LyricsPane(key: const ValueKey('lyrics'), item: item)
          : Center(
              key: const ValueKey('art'),
              child: LayoutBuilder(builder: (context, c) {
                final size = (c.biggest.shortestSide).clamp(160.0, 520.0);
                final art = item.artUri;
                return DecoratedBox(
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(24), boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 32, offset: const Offset(0, 12))]),
                  child: CoverArt(
                    albumId: item.albumId,
                    path: coverPath ?? (art != null && art.scheme == 'file' ? art.toFilePath() : null),
                    url: art != null && art.scheme.startsWith('http') ? art.toString() : null,
                    seed: item.album ?? item.title,
                    size: size,
                    radius: 24,
                    track: item.trackId == null ? null : null,
                  ),
                );
              }),
            ),
    );
  }

  Widget _controls(BuildContext context, MediaItem item, ColorScheme scheme) {
    final services = context.read<AppServices>();
    final player = services.player;
    final t = Theme.of(context);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
            InkWell(
              onTap: item.artistId == null ? null : () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ArtistScreen(artistId: item.artistId!))),
              child: Text(item.artist ?? 'Unknown artist', maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.titleMedium?.copyWith(color: scheme.onSurfaceVariant)),
            ),
          ]),
        ),
        if (item.trackId != null) _LoveButton(trackId: item.trackId!),
      ]),
      const SizedBox(height: 4),
      SeekBar(position: player.position, duration: item.duration ?? Duration.zero, onSeek: player.seek, activeColor: scheme.primary),
      StreamBuilder<PlaybackState>(
        stream: player.state,
        builder: (context, st) {
          final s = st.data;
          final playing = s?.playing ?? false;
          final loading = s?.processingState == AudioProcessingState.loading || s?.processingState == AudioProcessingState.buffering;
          final shuffle = s?.shuffleMode == AudioServiceShuffleMode.all;
          final repeat = s?.repeatMode ?? AudioServiceRepeatMode.none;
          return Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            IconButton(tooltip: 'Shuffle', isSelected: shuffle, icon: const Icon(Icons.shuffle), selectedIcon: Icon(Icons.shuffle, color: scheme.primary), onPressed: () => player.setShuffle(!shuffle)),
            IconButton(iconSize: 40, tooltip: 'Previous', icon: const Icon(Icons.skip_previous), onPressed: player.previous),
            SizedBox(
              width: 76,
              height: 76,
              child: loading && playing
                  ? const Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator())
                  : IconButton.filled(iconSize: 40, tooltip: playing ? 'Pause' : 'Play', icon: Icon(playing ? Icons.pause : Icons.play_arrow), onPressed: player.toggle),
            ),
            IconButton(iconSize: 40, tooltip: 'Next', icon: const Icon(Icons.skip_next), onPressed: player.next),
            IconButton(
              tooltip: 'Repeat',
              icon: Icon(repeat == AudioServiceRepeatMode.one ? Icons.repeat_one : Icons.repeat, color: repeat == AudioServiceRepeatMode.none ? null : scheme.primary),
              onPressed: player.cycleRepeat,
            ),
          ]);
        },
      ),
      const SizedBox(height: 4),
      Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
        IconButton(tooltip: _showLyrics ? 'Show cover' : 'Show lyrics', isSelected: _showLyrics, icon: const Icon(Icons.lyrics_outlined), selectedIcon: const Icon(Icons.lyrics), onPressed: () => setState(() => _showLyrics = !_showLyrics)),
        IconButton(tooltip: 'Queue', icon: const Icon(Icons.queue_music), onPressed: () => showQueueSheet(context)),
        StreamBuilder<SleepTimerState>(
          stream: player.sleepState,
          initialData: player.sleep,
          builder: (context, st) => IconButton(tooltip: 'Sleep timer', icon: Icon(st.data!.active ? Icons.bedtime : Icons.bedtime_outlined, color: st.data!.active ? scheme.primary : null), onPressed: () => showSleepTimerSheet(context)),
        ),
        IconButton(tooltip: 'Equalizer', icon: const Icon(Icons.equalizer), onPressed: () => showEqualizerSheet(context)),
        IconButton(tooltip: 'Playback speed', icon: const Icon(Icons.speed), onPressed: () => _speed(context)),
      ]),
    ]);
  }

  Future<void> _speed(BuildContext context) async {
    final player = context.read<AppServices>().player;
    const speeds = [0.75, 1.0, 1.25, 1.5, 2.0];
    final v = await showModalBottomSheet<double>(
      context: context,
      showDragHandle: true,
      builder: (s) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [for (final sp in speeds) ListTile(title: Text('${sp}x'), onTap: () => Navigator.pop(s, sp))])),
    );
    if (v != null) await player.setSpeed(v);
  }

  Future<void> _moreMenu(BuildContext context, MediaItem item) async {
    final services = context.read<AppServices>();
    final id = item.trackId;
    final track = id == null ? null : await services.repo.trackById(id);
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (s) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (track != null) ...[
            ListTile(leading: const Icon(Icons.playlist_add), title: const Text('Add to playlist…'), onTap: () {
              Navigator.pop(s);
              showAddToPlaylistSheet(context, [track]);
            }),
            if (track.albumId != null) ListTile(leading: const Icon(Icons.album), title: const Text('Go to album'), onTap: () {
              Navigator.pop(s);
              Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AlbumScreen(albumId: track.albumId!)));
            }),
            ListTile(leading: const Icon(Icons.auto_fix_high), title: const Text('Fix tags'), onTap: () {
              Navigator.pop(s);
              Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => IdentifyReviewScreen(track: track)));
            }),
            ListTile(leading: const Icon(Icons.radio), title: const Text('Start radio from this song'), onTap: () async {
              Navigator.pop(s);
              final plan = await services.radio.build(track);
              await services.player.playTracks(plan.local);
              if (context.mounted) showSnack(context, 'Radio: ${plan.local.length} songs (${plan.basis})');
            }),
            ListTile(leading: const Icon(Icons.info_outline), title: const Text('Details'), onTap: () {
              Navigator.pop(s);
              showTrackDetails(context, track);
            }),
          ],
          ListTile(leading: const Icon(Icons.stop_circle_outlined), title: const Text('Stop and clear queue'), onTap: () async {
            Navigator.pop(s);
            await services.player.clear();
            if (context.mounted) Navigator.of(context).maybePop();
          }),
        ]),
      ),
    );
  }
}

class _LoveButton extends StatelessWidget {
  const _LoveButton({required this.trackId});
  final int trackId;

  @override
  Widget build(BuildContext context) {
    final services = context.read<AppServices>();
    return StreamBuilder<Track?>(
      stream: services.db.watch(() => services.repo.trackById(trackId)),
      builder: (context, snap) {
        final loved = snap.data?.loved ?? false;
        return IconButton(
          tooltip: loved ? 'Remove from favourites' : 'Add to favourites',
          icon: Icon(loved ? Icons.favorite : Icons.favorite_border, color: loved ? Theme.of(context).colorScheme.error : null),
          onPressed: () async {
            await services.repo.setLoved(trackId, !loved);
            final t = snap.data;
            if (t != null && t.artistName != null && services.lastFm.canScrobble) {
              try {
                await services.lastFm.love(t.artistName!, t.title, love: !loved);
              } on Object {
                // offline
              }
            }
          },
        );
      },
    );
  }
}

class _LyricsPane extends StatelessWidget {
  const _LyricsPane({super.key, required this.item});
  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    final services = context.read<AppServices>();
    final id = item.trackId;
    if (id == null) return const EmptyState(icon: Icons.lyrics_outlined, title: 'No lyrics for streams', message: 'Download the song to get lyrics.');
    return FutureBuilder<Track?>(
      future: services.repo.trackById(id),
      builder: (context, ts) {
        final track = ts.data;
        if (track == null) return const Center(child: CircularProgressIndicator());
        return StreamBuilder<LyricsRow?>(
          stream: services.db.watch(() async {
            final cached = await services.lyrics.cached(track);
            if (cached != null && (cached.hasAny || cached.instrumental)) return cached;
            return services.lyrics.lyricsFor(track);
          }),
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
            final l = snap.data;
            return Stack(children: [
              if (l == null || (!l.hasAny && !l.instrumental))
                EmptyState(
                  icon: Icons.lyrics_outlined,
                  title: 'No lyrics found',
                  action: FilledButton.tonal(onPressed: () => showLyricsSheet(context, track), child: const Text('Search or add lyrics')),
                )
              else if (l.instrumental)
                const EmptyState(icon: Icons.piano, title: 'Instrumental')
              else
                LyricsView(position: services.player.position, synced: l.syncedLrc, plain: l.plainText, offsetMs: track.lyricsOffsetMs, onSeek: services.player.seek),
              Positioned(
                right: 0,
                top: 0,
                child: IconButton(tooltip: 'Lyrics options', icon: const Icon(Icons.tune), onPressed: () => showLyricsSheet(context, track)),
              ),
            ]);
          },
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Queue
// ---------------------------------------------------------------------------

Future<void> showQueueSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => const _QueueSheet(),
  );
}

class _QueueSheet extends StatelessWidget {
  const _QueueSheet();

  @override
  Widget build(BuildContext context) {
    final player = context.read<AppServices>().player;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scroll) => StreamBuilder<List<MediaItem>>(
        stream: player.queue,
        initialData: player.items,
        builder: (context, qs) {
          final items = qs.data ?? const [];
          return StreamBuilder<PlaybackState>(
            stream: player.state,
            builder: (context, st) {
              final index = st.data?.queueIndex ?? player.currentIndex;
              return Column(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
                  child: Row(children: [
                    Expanded(child: Text('Queue · ${items.length}', style: Theme.of(context).textTheme.titleMedium)),
                    TextButton(onPressed: items.isEmpty ? null : () async {
                      await player.clear();
                      if (context.mounted) Navigator.pop(context);
                    }, child: const Text('Clear')),
                  ]),
                ),
                Expanded(
                  child: ReorderableListView.builder(
                    scrollController: scroll,
                    itemCount: items.length,
                    onReorderItem: (o, n) => player.move(o, n),
                    itemBuilder: (context, i) {
                      final m = items[i];
                      final current = i == index;
                      return Dismissible(
                        key: ValueKey('${m.id}-$i'),
                        direction: DismissDirection.endToStart,
                        background: Container(color: Theme.of(context).colorScheme.errorContainer, alignment: Alignment.centerRight, padding: const EdgeInsets.only(right: 20), child: const Icon(Icons.delete)),
                        onDismissed: (_) => player.removeAt(i),
                        child: ListTile(
                          key: ValueKey('tile-${m.id}-$i'),
                          selected: current,
                          leading: CoverArt(albumId: m.albumId, url: m.artUri?.scheme.startsWith('http') == true ? m.artUri.toString() : null, path: m.artUri?.scheme == 'file' ? m.artUri!.toFilePath() : null, seed: m.album ?? m.title, size: 44),
                          title: Text(m.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(m.artist ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_handle)),
                          onTap: () => player.skipTo(i),
                        ),
                      );
                    },
                  ),
                ),
              ]);
            },
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sleep timer
// ---------------------------------------------------------------------------

Future<void> showSleepTimerSheet(BuildContext context) {
  final player = context.read<AppServices>().player;
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: StreamBuilder<SleepTimerState>(
        stream: player.sleepState,
        initialData: player.sleep,
        builder: (context, snap) {
          final s = snap.data!;
          return Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                s.mode == SleepMode.minutes
                    ? 'Stopping in ${formatDuration(s.remaining ?? Duration.zero)}'
                    : s.mode == SleepMode.endOfTrack
                        ? 'Stopping after this song'
                        : 'Sleep timer',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
              for (final m in const [5, 10, 15, 30, 45, 60, 90])
                ActionChip(label: Text('$m min'), onPressed: () {
                  player.startSleepMinutes(m);
                  Navigator.pop(sheet);
                }),
              ActionChip(avatar: const Icon(Icons.music_note, size: 18), label: const Text('End of song'), onPressed: () {
                player.startSleepEndOfTrack();
                Navigator.pop(sheet);
              }),
            ]),
            const SizedBox(height: 8),
            if (s.active) ...[
              if (s.mode == SleepMode.minutes) TextButton(onPressed: () => player.extendSleep(const Duration(minutes: 5)), child: const Text('+5 minutes')),
              TextButton(onPressed: () {
                player.cancelSleep();
                Navigator.pop(sheet);
              }, child: const Text('Turn off')),
            ],
            const SizedBox(height: 8),
          ]);
        },
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Equalizer
// ---------------------------------------------------------------------------

Future<void> showEqualizerSheet(BuildContext context) {
  return showModalBottomSheet<void>(context: context, showDragHandle: true, isScrollControlled: true, builder: (_) => const _EqualizerSheet());
}

class _EqualizerSheet extends StatefulWidget {
  const _EqualizerSheet();

  @override
  State<_EqualizerSheet> createState() => _EqualizerSheetState();
}

class _EqualizerSheetState extends State<_EqualizerSheet> {
  AndroidEqualizerParameters? _params;
  List<double> _gains = [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final services = context.read<AppServices>();
    final p = await services.player.equalizerParameters();
    if (!mounted) return;
    setState(() {
      _params = p;
      _loaded = true;
      final saved = services.settings.equalizerGains;
      _gains = p == null ? [] : [for (var i = 0; i < p.bands.length; i++) i < saved.length ? saved[i] : p.bands[i].gain];
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppServices>().settings;
    final p = _params;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SwitchListTile(title: const Text('Equalizer'), value: settings.equalizerEnabled, onChanged: p == null ? null : settings.setEqualizerEnabled),
          if (!_loaded)
            const Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator())
          else if (p == null)
            const Padding(padding: EdgeInsets.all(24), child: Text('The equalizer is available on Android once a song has started playing.'))
          else ...[
            SizedBox(
              height: 220,
              child: Row(children: [
                for (var i = 0; i < p.bands.length; i++)
                  Expanded(
                    child: Column(children: [
                      Text('${_gains[i].toStringAsFixed(0)}', style: Theme.of(context).textTheme.labelSmall),
                      Expanded(
                        child: RotatedBox(
                          quarterTurns: 3,
                          child: Slider(
                            min: p.minDecibels,
                            max: p.maxDecibels,
                            value: _gains[i].clamp(p.minDecibels, p.maxDecibels),
                            onChanged: settings.equalizerEnabled ? (v) => setState(() => _gains[i] = v) : null,
                            onChangeEnd: (_) => settings.setEqualizerGains(_gains),
                          ),
                        ),
                      ),
                      Text(_label(p.bands[i].centerFrequency), style: Theme.of(context).textTheme.labelSmall),
                    ]),
                  ),
              ]),
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              ActionChip(label: const Text('Flat'), onPressed: () => _preset(settings, p, (i, n) => 0)),
              ActionChip(label: const Text('Bass boost'), onPressed: () => _preset(settings, p, (i, n) => i < 2 ? p.maxDecibels * 0.6 : 0)),
              ActionChip(label: const Text('Treble boost'), onPressed: () => _preset(settings, p, (i, n) => i >= n - 2 ? p.maxDecibels * 0.6 : 0)),
              ActionChip(label: const Text('Vocal'), onPressed: () => _preset(settings, p, (i, n) => (i >= 1 && i <= n - 2) ? p.maxDecibels * 0.3 : -p.maxDecibels * 0.2)),
            ]),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Loudness boost'),
              subtitle: Slider(min: 0, max: 12, divisions: 12, label: '${settings.loudnessBoostDb.round()} dB', value: settings.loudnessBoostDb, onChanged: settings.setLoudnessBoostDb),
            ),
          ],
        ]),
      ),
    );
  }

  Future<void> _preset(dynamic settings, AndroidEqualizerParameters p, double Function(int i, int n) f) async {
    setState(() => _gains = [for (var i = 0; i < p.bands.length; i++) f(i, p.bands.length)]);
    await settings.setEqualizerEnabled(true);
    await settings.setEqualizerGains(_gains);
  }

  String _label(double hz) => hz >= 1000 ? '${(hz / 1000).toStringAsFixed(hz >= 10000 ? 0 : 1)}k' : hz.toStringAsFixed(0);
}
