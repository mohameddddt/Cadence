import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';

import '../../features/cover/image_processing.dart';

/// The colour of a cover, for tinting what sits around it: the mini player, the gradient behind
/// a playlist or album header, the Now Playing page. Averaged in a background isolate and cached.
class CoverTint {
  const CoverTint._();

  static final Map<String, Color?> _cache = {};
  static final Map<String, Future<Color?>> _pending = {};

  /// The cached colour, or null when it is unknown or still being worked out.
  static Color? peek(String? path) => path == null ? null : _cache[path];

  static Future<Color?> of(String? path) {
    if (path == null) return Future.value();
    if (_cache.containsKey(path)) return Future.value(_cache[path]);
    return _pending[path] ??= _compute(path);
  }

  static Future<Color?> _compute(String path) async {
    Color? c;
    try {
      if (File(path).existsSync()) {
        final argb = await Isolate.run(() async => ImageProcessing.averageColor(await File(path).readAsBytes()));
        if (argb != null) c = Color(argb);
      }
    } on Object {
      c = null;
    }
    _cache[path] = c;
    _pending.remove(path);
    return c;
  }

  /// [c] at lightness [l], with enough saturation to read as a colour (greys stay grey).
  static Color shade(Color c, double l) {
    final hsl = HSLColor.fromColor(c);
    final s = hsl.saturation < 0.08 ? hsl.saturation : (hsl.saturation * 1.15).clamp(0.3, 0.7);
    return hsl.withSaturation(s).withLightness(l).toColor();
  }
}

/// Rebuilds with the cover's colour once it is known (null until then, or when there is none).
class CoverTintBuilder extends StatefulWidget {
  const CoverTintBuilder({super.key, required this.path, required this.builder});

  final String? path;
  final Widget Function(BuildContext context, Color? tint) builder;

  @override
  State<CoverTintBuilder> createState() => _CoverTintBuilderState();
}

class _CoverTintBuilderState extends State<CoverTintBuilder> {
  Color? _tint;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(CoverTintBuilder old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) _load();
  }

  void _load() {
    final path = widget.path;
    _tint = CoverTint.peek(path);
    if (_tint != null || path == null) return;
    CoverTint.of(path).then((c) {
      if (mounted && widget.path == path) setState(() => _tint = c);
    });
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _tint);
}
