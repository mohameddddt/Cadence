import 'package:flutter/material.dart';

import '../../features/lyrics/lrc_parser.dart';

/// Synced lyrics: highlights the current line, auto-scrolls to it, tap a line to seek.
/// Falls back to plain scrolling text for unsynced lyrics (plan 6.2).
class LyricsView extends StatefulWidget {
  const LyricsView({
    super.key,
    required this.position,
    required this.onSeek,
    this.synced,
    this.plain,
    this.offsetMs = 0,
    this.textColor,
    this.activeColor,
  });

  final Stream<Duration> position;
  final ValueChanged<Duration> onSeek;
  final String? synced;
  final String? plain;

  /// Per-track sync offset (positive = show lyrics later).
  final int offsetMs;
  final Color? textColor;
  final Color? activeColor;

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> {
  late LrcDocument _doc;
  final ScrollController _scroll = ScrollController();
  final Map<int, GlobalKey> _keys = {};
  int _active = -1;
  bool _userScrolling = false;

  @override
  void initState() {
    super.initState();
    _doc = widget.synced == null ? LrcDocument.empty : LrcDocument.parse(widget.synced!);
  }

  @override
  void didUpdateWidget(LyricsView old) {
    super.didUpdateWidget(old);
    if (old.synced != widget.synced) {
      _doc = widget.synced == null ? LrcDocument.empty : LrcDocument.parse(widget.synced!);
      _keys.clear();
      _active = -1;
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _follow(int index) {
    if (index == _active) return;
    _active = index;
    if (_userScrolling) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _keys[index]?.currentContext;
      if (ctx != null && mounted) {
        Scrollable.ensureVisible(ctx, alignment: 0.4, duration: const Duration(milliseconds: 350), curve: Curves.easeOutCubic);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final base = widget.textColor ?? t.colorScheme.onSurfaceVariant;
    final active = widget.activeColor ?? t.colorScheme.onSurface;

    if (_doc.isEmpty) {
      final text = widget.plain?.trim();
      if (text == null || text.isEmpty) {
        return Center(child: Text('No lyrics', style: t.textTheme.bodyLarge?.copyWith(color: base)));
      }
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 48),
        child: Text(text, style: t.textTheme.titleMedium?.copyWith(color: active, height: 1.6), textAlign: TextAlign.center),
      );
    }

    return StreamBuilder<Duration>(
      stream: widget.position,
      builder: (context, snap) {
        final idx = _doc.indexAt(snap.data ?? Duration.zero, userOffsetMs: widget.offsetMs);
        _follow(idx);
        return NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n is ScrollStartNotification && n.dragDetails != null) _userScrolling = true;
            if (n is ScrollEndNotification) {
              // resume following a moment after the user lets go
              Future<void>.delayed(const Duration(seconds: 3), () => _userScrolling = false);
            }
            return false;
          },
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(24, 120, 24, 160),
            itemCount: _doc.lines.length,
            itemBuilder: (context, i) {
              final line = _doc.lines[i];
              final isActive = i == idx;
              return InkWell(
                key: _keys.putIfAbsent(i, GlobalKey.new),
                onTap: () => widget.onSeek(_doc.seekTimeFor(i, userOffsetMs: widget.offsetMs)),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 250),
                    style: (isActive ? t.textTheme.headlineSmall : t.textTheme.titleLarge)!.copyWith(
                      color: isActive ? active : base.withValues(alpha: 0.55),
                      fontWeight: isActive ? FontWeight.w800 : FontWeight.w600,
                    ),
                    child: Text(line.text.isEmpty ? '♪' : line.text, textAlign: TextAlign.center),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}
