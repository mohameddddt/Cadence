import 'package:flutter/material.dart';

import '../../app/theme.dart';
import 'kit.dart';

String formatDuration(Duration d) {
  final total = d.inSeconds < 0 ? 0 : d.inSeconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}

String formatMs(int ms) => formatDuration(Duration(milliseconds: ms));

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB'];
  var v = bytes / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v < 10 ? 1 : 0)} ${units[i]}';
}

void showSnack(BuildContext context, String message, {SnackBarAction? action, Duration? duration}) {
  final m = ScaffoldMessenger.maybeOf(context);
  if (m == null) return;
  m
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message), action: action, duration: duration ?? const Duration(seconds: 4), behavior: SnackBarBehavior.floating));
}

/// Space to leave under scrolling content: inside the shell the floating dock and mini player
/// report their height as bottom padding, elsewhere it is the system navigation bar.
double bottomClearance(BuildContext context) => MediaQuery.paddingOf(context).bottom + 24;

/// An editorial section title in the display face, with an optional eyebrow above it.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing, this.onTap, this.eyebrow});

  final String title;
  final Widget? trailing;
  final VoidCallback? onTap;
  final String? eyebrow;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Semantics(
      header: true,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 26, 10, 10),
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (eyebrow != null) Padding(padding: const EdgeInsets.only(bottom: 4), child: Eyebrow(eyebrow!)),
                Text(title, style: t.textTheme.headlineMedium),
              ]),
            ),
            if (trailing != null) trailing!,
            if (onTap != null && trailing == null) Icon(Icons.arrow_forward_rounded, size: 20, color: t.colorScheme.onSurfaceVariant),
          ]),
        ),
      ),
    );
  }
}

/// A quiet empty screen: a thin ring around the icon, a display-face title and one line of help.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action});

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(36),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: context.tokens.hairline)),
            child: Icon(icon, size: 30, color: t.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 24),
          Text(title, style: t.textTheme.headlineMedium, textAlign: TextAlign.center),
          if (message != null) ...[
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 300),
              child: Text(message!, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant), textAlign: TextAlign.center),
            ),
          ],
          if (action != null) ...[const SizedBox(height: 24), action!],
        ]),
      ),
    );
  }
}

/// Picks a stable pastel-ish colour pair from text (placeholder covers).
({Color a, Color b}) placeholderColors(String seed, Brightness brightness) {
  var h = 0;
  for (final c in seed.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  final hue = (h % 360).toDouble();
  final sat = brightness == Brightness.dark ? 0.45 : 0.5;
  final light = brightness == Brightness.dark ? 0.32 : 0.62;
  return (
    a: HSLColor.fromAHSL(1, hue, sat, light).toColor(),
    b: HSLColor.fromAHSL(1, (hue + 40) % 360, sat, light * 0.8).toColor(),
  );
}

String initialsOf(String s) {
  final words = s.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return '♪';
  if (words.length == 1) return words.first.substring(0, 1).toUpperCase();
  return (words.first.substring(0, 1) + words[1].substring(0, 1)).toUpperCase();
}
