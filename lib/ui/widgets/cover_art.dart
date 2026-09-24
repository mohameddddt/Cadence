import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/app_services.dart';
import '../../app/cover_cache.dart';
import '../../core/models/track.dart';
import 'common.dart';

/// Artwork with a generated gradient + initials placeholder (plan 5.1 step 7).
///
/// Resolution order: explicit file/URL -> album cover from the cache -> the picture embedded
/// in the track -> placeholder.
class CoverArt extends StatelessWidget {
  const CoverArt({
    super.key,
    this.albumId,
    this.track,
    this.path,
    this.url,
    this.size = 48,
    this.radius = 8,
    this.seed = '',
    this.circle = false,
    this.artistId,
  });

  final int? albumId;
  final int? artistId;
  final Track? track;
  final String? path;
  final String? url;
  final double size;
  final double radius;
  final String seed;
  final bool circle;

  @override
  Widget build(BuildContext context) {
    final shape = circle ? BorderRadius.circular(size) : BorderRadius.circular(radius);
    return ClipRRect(
      borderRadius: shape,
      child: SizedBox(width: size, height: size, child: _content(context)),
    );
  }

  Widget _content(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cache = (size * dpr).round().clamp(64, 1400);
    Widget file(String p) => Image.file(
          File(p),
          fit: BoxFit.cover,
          cacheWidth: cache,
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, _, _) => _placeholder(context),
          excludeFromSemantics: true,
        );

    if (path != null && File(path!).existsSync()) return file(path!);
    if (url != null && url!.isNotEmpty) {
      return Image.network(url!, fit: BoxFit.cover, cacheWidth: cache, gaplessPlayback: true, errorBuilder: (_, _, _) => _placeholder(context), excludeFromSemantics: true);
    }
    final services = context.read<AppServices?>();
    if (services == null) return _placeholder(context);
    return ListenableBuilder(
      listenable: services.coverCache,
      builder: (context, _) {
        final CoverCache cc = services.coverCache;
        final p = albumId != null ? cc.albumCover(albumId) : (artistId != null ? cc.artistImage(artistId) : cc.albumCover(track?.albumId));
        if (p != null) return file(p);
        final t = track;
        if (t != null && t.hasEmbeddedArt) {
          return FutureBuilder<File?>(
            future: services.covers.extractEmbedded(t),
            builder: (context, snap) => snap.data != null ? file(snap.data!.path) : _placeholder(context),
          );
        }
        return _placeholder(context);
      },
    );
  }

  Widget _placeholder(BuildContext context) {
    final label = seed.isNotEmpty ? seed : (track?.albumTitle ?? track?.title ?? '');
    final colors = placeholderColors(label, Theme.of(context).brightness);
    return Container(
      decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [colors.a, colors.b])),
      alignment: Alignment.center,
      child: Text(initialsOf(label), style: TextStyle(color: Colors.white.withValues(alpha: 0.9), fontSize: size * 0.34, fontWeight: FontWeight.w700)),
    );
  }
}
