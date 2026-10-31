import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/app_services.dart';
import '../../core/models/track.dart';
import '../../features/playback/media_items.dart';
import '../screens/now_playing_screen.dart';
import 'cover_art.dart';
import 'cover_tint.dart';

/// Always-visible player above the bottom bar, tinted with the cover's colour. Tap to expand,
/// swipe sideways to skip, swipe up to open (plan phase 8 gestures).
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final services = context.read<AppServices>();
    final player = services.player;
    return StreamBuilder<MediaItem?>(
      stream: player.currentItem,
      builder: (context, snap) {
        final item = snap.data;
        if (item == null) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        final art = item.artUri;
        final coverPath = services.coverCache.albumCover(item.albumId) ?? (art != null && art.scheme == 'file' ? art.toFilePath() : null);
        return Semantics(
          container: true,
          label: 'Now playing ${item.title} by ${item.artist ?? 'unknown artist'}. Double tap to open.',
          child: GestureDetector(
            onTap: () => openNowPlaying(context),
            onVerticalDragEnd: (d) {
              if ((d.primaryVelocity ?? 0) < -300) openNowPlaying(context);
            },
            onHorizontalDragEnd: (d) {
              final v = d.primaryVelocity ?? 0;
              if (v < -400) player.next();
              if (v > 400) player.previous();
            },
            child: CoverTintBuilder(
              path: coverPath,
              builder: (context, tint) {
                // On a cover tint the text is white; without one it follows the theme.
                final bg = tint == null ? scheme.surfaceContainerHigh : CoverTint.shade(tint, 0.24);
                final fg = tint == null ? scheme.onSurface : Colors.white;
                final fgSub = tint == null ? scheme.onSurfaceVariant : Colors.white70;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 400),
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  height: 60,
                  decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
                      child: Row(children: [
                        Hero(tag: 'now-playing-art', child: _MiniArt(item: item)),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                            Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: fg)),
                            Text(item.artist ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: fgSub)),
                          ]),
                        ),
                        if (item.trackId != null) _SavedButton(trackId: item.trackId!, color: fg),
                        StreamBuilder(
                          stream: player.state,
                          builder: (context, st) {
                            final playing = st.data?.playing ?? false;
                            final loading = st.data?.processingState == AudioProcessingState.loading || st.data?.processingState == AudioProcessingState.buffering;
                            if (loading && playing) {
                              return SizedBox.square(dimension: 48, child: Padding(padding: const EdgeInsets.all(14), child: CircularProgressIndicator(strokeWidth: 2, strokeCap: StrokeCap.round, color: fg)));
                            }
                            return IconButton(
                              tooltip: playing ? 'Pause' : 'Play',
                              iconSize: 32,
                              color: fg,
                              icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                              onPressed: player.toggle,
                            );
                          },
                        ),
                      ]),
                    ),
                    Positioned(left: 8, right: 8, bottom: 0, child: _MiniProgress(item: item, color: fg)),
                  ]),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

/// Saved-to-favourites toggle: an accent check when saved, an outlined plus when not.
class _SavedButton extends StatelessWidget {
  const _SavedButton({required this.trackId, required this.color});
  final int trackId;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    return StreamBuilder<Track?>(
      stream: s.db.watch(() => s.repo.trackById(trackId)),
      builder: (context, snap) {
        final loved = snap.data?.loved ?? false;
        return IconButton(
          tooltip: loved ? 'Remove from favourites' : 'Add to favourites',
          icon: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
            child: loved
                ? Icon(Icons.check_circle_rounded, key: const ValueKey(true), color: Theme.of(context).colorScheme.primary, size: 26)
                : Icon(Icons.add_circle_outline_rounded, key: const ValueKey(false), color: color, size: 26),
          ),
          onPressed: () => s.repo.setLoved(trackId, !loved),
        );
      },
    );
  }
}

class _MiniArt extends StatelessWidget {
  const _MiniArt({required this.item});
  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    final art = item.artUri;
    return CoverArt(
      albumId: item.albumId,
      path: art != null && art.scheme == 'file' ? art.toFilePath() : null,
      url: art != null && art.scheme.startsWith('http') ? art.toString() : null,
      seed: item.album ?? item.title,
      size: 44,
      radius: 4,
    );
  }
}

class _MiniProgress extends StatelessWidget {
  const _MiniProgress({required this.item, required this.color});
  final MediaItem item;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final services = context.read<AppServices>();
    final total = item.duration?.inMilliseconds ?? 0;
    if (total <= 0) return const SizedBox.shrink();
    return StreamBuilder<Duration>(
      stream: services.player.position,
      builder: (context, snap) => LinearProgressIndicator(
        minHeight: 2.5,
        value: ((snap.data?.inMilliseconds ?? 0) / total).clamp(0.0, 1.0),
        color: color,
        backgroundColor: color.withValues(alpha: 0.2),
      ),
    );
  }
}
