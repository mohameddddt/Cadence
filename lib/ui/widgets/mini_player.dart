import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/app_services.dart';
import '../../features/playback/media_items.dart';
import '../screens/now_playing_screen.dart';
import 'cover_art.dart';

/// Always-visible player above the navigation bar. Tap to expand, swipe sideways to skip,
/// swipe up to open (plan phase 8 gestures).
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
        final t = Theme.of(context);
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
            child: Container(
              margin: const EdgeInsets.fromLTRB(8, 0, 8, 4),
              decoration: BoxDecoration(color: t.colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(16)),
              clipBehavior: Clip.antiAlias,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
                  child: Row(children: [
                    _MiniArt(item: item),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                        Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.titleSmall?.copyWith(color: t.colorScheme.onSecondaryContainer, fontWeight: FontWeight.w700)),
                        Text(item.artist ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSecondaryContainer.withValues(alpha: 0.8))),
                      ]),
                    ),
                    StreamBuilder(
                      stream: player.state,
                      builder: (context, st) {
                        final playing = st.data?.playing ?? false;
                        final loading = st.data?.processingState == AudioProcessingState.loading || st.data?.processingState == AudioProcessingState.buffering;
                        return Row(mainAxisSize: MainAxisSize.min, children: [
                          IconButton(tooltip: 'Previous', icon: const Icon(Icons.skip_previous), color: t.colorScheme.onSecondaryContainer, onPressed: player.previous),
                          loading && playing
                              ? const SizedBox(width: 48, height: 48, child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 3)))
                              : IconButton.filled(tooltip: playing ? 'Pause' : 'Play', icon: Icon(playing ? Icons.pause : Icons.play_arrow), onPressed: player.toggle),
                          IconButton(tooltip: 'Next', icon: const Icon(Icons.skip_next), color: t.colorScheme.onSecondaryContainer, onPressed: player.next),
                        ]);
                      },
                    ),
                  ]),
                ),
                _MiniProgress(item: item),
              ]),
            ),
          ),
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
      radius: 10,
    );
  }
}

class _MiniProgress extends StatelessWidget {
  const _MiniProgress({required this.item});
  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    final services = context.read<AppServices>();
    final total = item.duration?.inMilliseconds ?? 0;
    if (total <= 0) return const SizedBox(height: 2);
    return StreamBuilder<Duration>(
      stream: services.player.position,
      builder: (context, snap) => LinearProgressIndicator(minHeight: 2, value: ((snap.data?.inMilliseconds ?? 0) / total).clamp(0.0, 1.0), backgroundColor: Colors.transparent),
    );
  }
}
