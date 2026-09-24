import 'dart:async';

import 'package:flutter/material.dart';

import 'common.dart';

/// Position slider with elapsed/remaining labels. While dragging it shows the drag position
/// and only seeks on release, so the stream's updates do not fight the thumb.
class SeekBar extends StatefulWidget {
  const SeekBar({super.key, required this.position, required this.duration, required this.onSeek, this.activeColor});

  final Stream<Duration> position;
  final Duration duration;
  final ValueChanged<Duration> onSeek;
  final Color? activeColor;

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final total = widget.duration.inMilliseconds.toDouble();
    return StreamBuilder<Duration>(
      stream: widget.position,
      builder: (context, snap) {
        final pos = (snap.data?.inMilliseconds ?? 0).toDouble();
        final value = (_drag ?? pos).clamp(0.0, total <= 0 ? 1.0 : total);
        return Column(children: [
          Semantics(
            label: 'Seek',
            value: '${formatMs(value.round())} of ${formatMs(total.round())}',
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(activeTrackColor: widget.activeColor, thumbColor: widget.activeColor, overlayShape: SliderComponentShape.noOverlay),
              child: Slider(
                min: 0,
                max: total <= 0 ? 1 : total,
                value: value,
                onChanged: total <= 0 ? null : (v) => setState(() => _drag = v),
                onChangeEnd: (v) {
                  widget.onSeek(Duration(milliseconds: v.round()));
                  // keep showing the release position until the player reports it
                  Timer(const Duration(milliseconds: 300), () {
                    if (mounted) setState(() => _drag = null);
                  });
                },
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text(formatMs(value.round()), style: Theme.of(context).textTheme.labelSmall),
              Text(total <= 0 ? '--:--' : '-${formatMs((total - value).round())}', style: Theme.of(context).textTheme.labelSmall),
            ]),
          ),
        ]);
      },
    );
  }
}
