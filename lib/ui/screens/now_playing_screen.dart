import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart' show AndroidEqualizerParameters;
import 'package:provider/provider.dart';

import '../../app/app_services.dart';
import '../../app/theme.dart';
import '../../core/settings/settings_store.dart';
import '../../core/models/library_models.dart';
import '../../core/models/track.dart';
import '../../features/playback/media_items.dart';
import '../../features/playback/sleep_timer.dart';
import '../widgets/common.dart';
import '../widgets/cover_art.dart';
import '../widgets/cover_tint.dart';
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

  Future<void> _updateScheme(String? coverPath, Brightness brightness, bool pureBlackDark) async {
    final key = '$coverPath|$brightness|$pureBlackDark';
    if (key == _schemeFor) return;
    _schemeFor = key;
    if (coverPath == null || !File(coverPath).existsSync()) {
      if (mounted) setState(() => _scheme = null);
      return;
    }
    try {
      final s = await AppTheme.fromCover(ResizeImage(FileImage(File(coverPath)), width: 96), brightness, pureBlackDark: pureBlackDark);
      if (mounted && _schemeFor == key) setState(() => _scheme = s);
    } on Object {
      // keep the app colours
    }
  }

  @override
  Widget build(BuildContext context) {
    final services = context.read<AppServices>();
    final settings = context.watch<SettingsStore>();
    final player = services.player;
    final base = Theme.of(context);
    final useCover = settings.coverColors;
    return StreamBuilder<MediaItem?>(
      stream: player.currentItem,
      builder: (context, snap) {
        final item = snap.data;
        if (item == null) return Scaffold(appBar: AppBar(), body: const EmptyState(icon: Icons.music_off_rounded, title: 'Nothing is playing'));
        final coverPath = services.coverCache.albumCover(item.albumId) ?? (item.artUri?.scheme == 'file' ? item.artUri!.toFilePath() : null);
        final hasCover = coverPath != null && File(coverPath).existsSync();
        if (useCover) _updateScheme(coverPath, base.brightness, settings.pureBlack);
        final theme = useCover && _scheme != null ? AppTheme.themeFor(_scheme!, settings.fontPairing) : base;
        final scheme = theme.colorScheme;
        return Theme(
          data: theme,
          child: GestureDetector(
            onVerticalDragEnd: (d) {
              if ((d.primaryVelocity ?? 0) > 700) Navigator.of(context).maybePop();
            },
            child: CoverTintBuilder(
              path: settings.ambientBackdrop && hasCover ? coverPath : null,
              builder: (context, tint) {
                // The page takes the cover's colour at the top and sinks into the page colour.
                final dark = theme.brightness == Brightness.dark;
                final top = tint == null ? scheme.surface : CoverTint.shade(tint, dark ? 0.36 : 0.82);
                final mid = tint == null ? scheme.surface : CoverTint.shade(tint, dark ? 0.16 : 0.9);
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 600),
                  decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, stops: const [0, 0.6, 1], colors: [top, mid, scheme.surface])),
                  child: Scaffold(
                    backgroundColor: Colors.transparent,
                    body: SafeArea(
                      child: LayoutBuilder(builder: (context, c) {
                        final wide = c.maxWidth > 700;
                        final art = _artOrLyrics(context, item, scheme, coverPath);
                        final controls = _controls(context, item, scheme);
                        if (wide) {
                          return Column(children: [
                            _topBar(context, item),
                            Expanded(
                              child: Row(children: [
                                Expanded(child: Padding(padding: const EdgeInsets.all(24), child: art)),
                                Expanded(child: Padding(padding: const EdgeInsets.all(24), child: Center(child: controls))),
                              ]),
                            ),
                          ]);
                        }
                        // One screen of player, then the lyrics card to scroll up to.
                        return SingleChildScrollView(
                          child: Column(children: [
                            SizedBox(
                              height: c.maxHeight,
                              child: Column(children: [
                                _topBar(context, item),
                                Expanded(child: Padding(padding: const EdgeInsets.fromLTRB(24, 20, 24, 20), child: art)),
                                Padding(padding: const EdgeInsets.fromLTRB(24, 0, 24, 6), child: controls),
                              ]),
                            ),
                            if (item.trackId != null) _LyricsCard(item: item, color: tint == null ? scheme.surfaceContainerHigh : CoverTint.shade(tint, dark ? 0.42 : 0.7)),
                            const SizedBox(height: 24),
                          ]),
                        );
                      }),
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  Widget _topBar(BuildContext context, MediaItem item) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 0),
      child: Row(children: [
        IconButton(tooltip: 'Close', iconSize: 32, icon: const Icon(Icons.keyboard_arrow_down_rounded), onPressed: () => Navigator.of(context).maybePop()),
        Expanded(
          child: Column(children: [
            Text(item.album == null ? 'PLAYING FROM YOUR QUEUE' : 'PLAYING FROM ALBUM', style: t.textTheme.labelSmall?.copyWith(letterSpacing: 1.4)),
            const SizedBox(height: 2),
            Text(item.album ?? 'Your queue', maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
          ]),
        ),
        IconButton(tooltip: 'More', icon: const Icon(Icons.more_vert_rounded), onPressed: () => _moreMenu(context, item)),
      ]),
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
                return Hero(
                  tag: 'now-playing-art',
                  child: DecoratedBox(
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 36, offset: const Offset(0, 16))]),
                    child: CoverArt(
                      albumId: item.albumId,
                      path: coverPath ?? (art != null && art.scheme == 'file' ? art.toFilePath() : null),
                      url: art != null && art.scheme.startsWith('http') ? art.toString() : null,
                      seed: item.album ?? item.title,
                      size: size,
                      radius: 8,
                    ),
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
    Widget toggle({required String tooltip, required IconData icon, required bool on, required VoidCallback onPressed}) => IconButton(
          tooltip: tooltip,
          onPressed: onPressed,
          icon: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: on ? scheme.primary : scheme.onSurface.withValues(alpha: 0.75), size: 28),
            const SizedBox(height: 2),
            Container(width: 4, height: 4, decoration: BoxDecoration(color: on ? scheme.primary : Colors.transparent, shape: BoxShape.circle)),
          ]),
        );
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.headlineLarge),
            const SizedBox(height: 2),
            InkWell(
              onTap: item.artistId == null ? null : () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ArtistScreen(artistId: item.artistId!))),
              child: Text(item.artist ?? 'Unknown artist', maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.bodyLarge?.copyWith(color: scheme.onSurface.withValues(alpha: 0.72))),
            ),
          ]),
        ),
        if (item.trackId != null) _LoveButton(trackId: item.trackId!),
      ]),
      const SizedBox(height: 12),
      SeekBar(position: player.position, duration: item.duration ?? Duration.zero, onSeek: player.seek, activeColor: scheme.onSurface),
      StreamBuilder<PlaybackState>(
        stream: player.state,
        builder: (context, st) {
          final s = st.data;
          final playing = s?.playing ?? false;
          final loading = s?.processingState == AudioProcessingState.loading || s?.processingState == AudioProcessingState.buffering;
          final shuffle = s?.shuffleMode == AudioServiceShuffleMode.all;
          final repeat = s?.repeatMode ?? AudioServiceRepeatMode.none;
          return Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            toggle(tooltip: 'Shuffle', icon: Icons.shuffle_rounded, on: shuffle, onPressed: () => player.setShuffle(!shuffle)),
            IconButton(iconSize: 44, tooltip: 'Previous', icon: const Icon(Icons.skip_previous_rounded), onPressed: player.previous),
            SizedBox.square(
              dimension: 70,
              child: Material(
                color: scheme.onSurface,
                shape: const CircleBorder(),
                child: loading && playing
                    ? Padding(padding: const EdgeInsets.all(23), child: CircularProgressIndicator(strokeWidth: 2.5, strokeCap: StrokeCap.round, color: scheme.surface))
                    : IconButton(
                        iconSize: 40,
                        tooltip: playing ? 'Pause' : 'Play',
                        color: scheme.surface,
                        icon: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 180),
                          transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                          child: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, key: ValueKey(playing)),
                        ),
                        onPressed: player.toggle,
                      ),
              ),
            ),
            IconButton(iconSize: 44, tooltip: 'Next', icon: const Icon(Icons.skip_next_rounded), onPressed: player.next),
            toggle(
              tooltip: 'Repeat',
              icon: repeat == AudioServiceRepeatMode.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
              on: repeat != AudioServiceRepeatMode.none,
              onPressed: player.cycleRepeat,
            ),
          ]);
        },
      ),
      const SizedBox(height: 6),
      Row(children: [
        IconButton(
          tooltip: _showLyrics ? 'Show cover' : 'Show lyrics',
          icon: Icon(_showLyrics ? Icons.lyrics_rounded : Icons.lyrics_outlined, color: _showLyrics ? scheme.primary : null),
          onPressed: () => setState(() => _showLyrics = !_showLyrics),
        ),
        StreamBuilder<SleepTimerState>(
          stream: player.sleepState,
          initialData: player.sleep,
          builder: (context, st) => IconButton(
            tooltip: 'Sleep timer',
            icon: Icon(st.data!.active ? Icons.bedtime_rounded : Icons.bedtime_outlined, color: st.data!.active ? scheme.primary : null),
            onPressed: () => showSleepTimerSheet(context),
          ),
        ),
        const Spacer(),
        IconButton(tooltip: 'Equalizer', icon: const Icon(Icons.graphic_eq_rounded), onPressed: () => showEqualizerSheet(context)),
        IconButton(tooltip: 'Playback speed', icon: const Icon(Icons.speed_rounded), onPressed: () => _speed(context)),
        IconButton(tooltip: 'Queue', icon: const Icon(Icons.queue_music_rounded), onPressed: () => showQueueSheet(context)),
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
          icon: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            transitionBuilder: (c, a) => ScaleTransition(scale: CurvedAnimation(parent: a, curve: Curves.easeOutBack), child: c),
            child: Icon(loved ? Icons.check_circle_rounded : Icons.add_circle_outline_rounded, key: ValueKey(loved), size: 30, color: loved ? Theme.of(context).colorScheme.primary : null),
          ),
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

/// Lyrics on a card in the cover's colour, below the player.
class _LyricsCard extends StatelessWidget {
  const _LyricsCard({required this.item, required this.color});
  final MediaItem item;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final onCard = color.computeLuminance() > 0.4 ? Colors.black : Colors.white;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 600),
        height: 420,
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(12)),
        child: Theme(
          data: t.copyWith(colorScheme: t.colorScheme.copyWith(onSurface: onCard, primary: onCard, onSurfaceVariant: onCard.withValues(alpha: 0.7))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Lyrics', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800, color: onCard)),
            const SizedBox(height: 6),
            Expanded(child: _LyricsPane(item: item)),
          ]),
        ),
      ),
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
                      Text(_gains[i].toStringAsFixed(0), style: Theme.of(context).textTheme.labelSmall),
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
