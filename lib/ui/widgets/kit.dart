import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// Lumen-style building blocks: frosted glass, editorial titles, pills and the floating dock.

// ---------------------------------------------------------------------------
// Glass
// ---------------------------------------------------------------------------

/// Frosted glass: blurs whatever is drawn behind it and lays a translucent tint on top.
class Glass extends StatelessWidget {
  const Glass({super.key, required this.child, this.borderRadius = const BorderRadius.all(Radius.circular(100)), this.tint, this.border, this.shadow = false});

  final Widget child;
  final BorderRadius borderRadius;
  final Color? tint;
  final Color? border;
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final tk = context.tokens;
    Widget glass = ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: tk.blur, sigmaY: tk.blur),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: tint ?? tk.glassTint,
            borderRadius: borderRadius,
            border: Border.all(color: border ?? tk.glassBorder),
          ),
          child: child,
        ),
      ),
    );
    if (shadow) {
      glass = CustomPaint(painter: _OuterShadowPainter(borderRadius, Colors.black.withValues(alpha: tk.isDark ? 0.45 : 0.16)), child: glass);
    }
    return glass;
  }
}

/// A soft drop shadow drawn only outside the shape, so it never shows through translucent glass.
class _OuterShadowPainter extends CustomPainter {
  _OuterShadowPainter(this.radius, this.color);

  final BorderRadius radius;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final shape = radius.toRRect(Offset.zero & size);
    final outside = Path.combine(PathOperation.difference, Path()..addRect((Offset.zero & size).inflate(80)), Path()..addRRect(shape));
    canvas
      ..save()
      ..clipPath(outside)
      ..drawRRect(shape.shift(const Offset(0, 10)), Paint()
        ..color = color
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14))
      ..restore();
  }

  @override
  bool shouldRepaint(_OuterShadowPainter old) => old.radius != radius || old.color != color;
}

// ---------------------------------------------------------------------------
// Type
// ---------------------------------------------------------------------------

/// A small spaced-out uppercase label above titles and sections.
class Eyebrow extends StatelessWidget {
  const Eyebrow(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final style = t.textTheme.labelSmall!;
    return Text(
      text.toUpperCase(),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style.copyWith(letterSpacing: (style.letterSpacing ?? 0.4) * 4, color: color ?? t.colorScheme.onSurfaceVariant),
    );
  }
}

/// The large editorial title of a top-level screen, for an [AppBar]'s title (with [screenTitleHeight]).
class ScreenTitle extends StatelessWidget {
  const ScreenTitle(this.title, {super.key, this.eyebrow});

  final String title;
  final String? eyebrow;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      if (eyebrow != null) Padding(padding: const EdgeInsets.only(bottom: 4), child: Eyebrow(eyebrow!)),
      Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.displaySmall?.copyWith(color: t.colorScheme.onSurface)),
    ]);
  }
}

/// AppBar toolbar height that fits a [ScreenTitle].
const double screenTitleHeight = 84;

// ---------------------------------------------------------------------------
// Buttons
// ---------------------------------------------------------------------------

class RoundIconButton extends StatelessWidget {
  const RoundIconButton({super.key, required this.icon, required this.tooltip, required this.onPressed, this.size = 44, this.iconSize = 20, this.color, this.iconColor, this.glass = false});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;
  final double iconSize;
  final Color? color;
  final Color? iconColor;

  /// Frosted background instead of a solid one, for buttons over artwork.
  final bool glass;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final content = SizedBox(
      width: size,
      height: size,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: Icon(icon, size: iconSize, color: iconColor ?? scheme.onSurface),
        ),
      ),
    );
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        excludeSemantics: true,
        child: glass ? Glass(child: content) : DecoratedBox(decoration: ShapeDecoration(color: color ?? scheme.surfaceContainerHigh, shape: const CircleBorder()), child: content),
      ),
    );
  }
}

/// A capsule button: ink-filled for the main action, hairline-outlined otherwise.
class PillButton extends StatelessWidget {
  const PillButton({super.key, required this.label, required this.onPressed, this.icon, this.filled = true, this.accent = true, this.height = 48, this.expand = false});

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool filled;

  /// Fill with the palette accent (default) or, when false, with ink.
  final bool accent;
  final double height;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final scheme = t.colorScheme;
    final enabled = onPressed != null;
    final bg = !filled ? Colors.transparent : (!enabled ? scheme.surfaceContainerHigh : (accent ? scheme.primary : scheme.inverseSurface));
    final fg = !enabled ? scheme.onSurfaceVariant : (!filled ? scheme.onSurface : (accent ? scheme.onPrimary : scheme.onInverseSurface));
    return SizedBox(
      height: height,
      width: expand ? double.infinity : null,
      child: Material(
        color: bg,
        shape: StadiumBorder(side: filled ? BorderSide.none : BorderSide(color: context.tokens.hairline)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
              if (icon != null) ...[Icon(icon, size: 18, color: fg), const SizedBox(width: 8)],
              Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.titleSmall?.copyWith(color: fg))),
            ]),
          ),
        ),
      ),
    );
  }
}

/// A selectable capsule: hairline when off, ink when on.
class PillChip extends StatelessWidget {
  const PillChip({super.key, required this.label, required this.selected, required this.onTap, this.icon});

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final scheme = t.colorScheme;
    final fg = selected ? scheme.onPrimary : scheme.onSurface;
    return Semantics(
      selected: selected,
      button: true,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        decoration: ShapeDecoration(color: selected ? scheme.primary : scheme.surfaceContainerHigh, shape: const StadiumBorder()),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (icon != null) ...[Icon(icon, size: 16, color: fg), const SizedBox(width: 6)],
                Text(label, style: t.textTheme.labelLarge?.copyWith(color: fg)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// A row of options with a raised thumb that slides to the selected one.
class SegmentedPills<T> extends StatelessWidget {
  const SegmentedPills({super.key, required this.options, required this.selected, required this.label, required this.onSelect});

  final List<T> options;
  final T selected;
  final String Function(T) label;
  final ValueChanged<T> onSelect;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final scheme = t.colorScheme;
    final index = math.max(0, options.indexOf(selected));
    return Container(
      height: 46,
      padding: const EdgeInsets.all(4),
      decoration: ShapeDecoration(color: scheme.surfaceContainerHigh, shape: const StadiumBorder()),
      child: LayoutBuilder(builder: (context, c) {
        final segment = c.maxWidth / options.length;
        return Stack(children: [
          AnimatedPositioned(
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutBack,
            left: segment * index,
            top: 0,
            bottom: 0,
            width: segment,
            child: DecoratedBox(
              decoration: ShapeDecoration(
                color: context.tokens.raised,
                shape: const StadiumBorder(),
                shadows: [BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 4, offset: const Offset(0, 1))],
              ),
            ),
          ),
          Row(children: [
            for (final o in options)
              Expanded(
                child: Semantics(
                  selected: o == selected,
                  button: true,
                  child: InkWell(
                    customBorder: const StadiumBorder(),
                    onTap: () => onSelect(o),
                    child: Center(
                      child: Text(label(o), style: t.textTheme.labelLarge?.copyWith(color: o == selected ? scheme.onSurface : scheme.onSurfaceVariant)),
                    ),
                  ),
                ),
              ),
          ]),
        ]);
      }),
    );
  }
}

// ---------------------------------------------------------------------------
// Bottom bar
// ---------------------------------------------------------------------------

class DockItem {
  const DockItem(this.label, this.icon, this.selectedIcon, {this.badge = 0});

  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final int badge;
}

/// Full-width tab bar over a fade to black, so content scrolling under it dissolves.
class BottomBar extends StatelessWidget {
  const BottomBar({super.key, required this.items, required this.selectedIndex, required this.onSelect});

  final List<DockItem> items;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final scheme = t.colorScheme;
    final base = context.tokens.isDark ? Colors.black : scheme.surface;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: const [0, 0.45, 1],
          colors: [base.withValues(alpha: 0), base.withValues(alpha: 0.92), base],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.only(top: 20, bottom: 6),
          child: Row(children: [
            for (var i = 0; i < items.length; i++)
              Expanded(child: _BarItem(item: items[i], selected: i == selectedIndex, onTap: () => onSelect(i), scheme: scheme, textTheme: t.textTheme)),
          ]),
        ),
      ),
    );
  }
}

class _BarItem extends StatelessWidget {
  const _BarItem({required this.item, required this.selected, required this.onTap, required this.scheme, required this.textTheme});

  final DockItem item;
  final bool selected;
  final VoidCallback onTap;
  final ColorScheme scheme;
  final TextTheme textTheme;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? scheme.onSurface : scheme.onSurfaceVariant;
    Widget icon = Icon(selected ? item.selectedIcon : item.icon, size: 26, color: fg);
    if (item.badge > 0) icon = Badge(label: Text('${item.badge}'), offset: const Offset(8, -4), child: icon);
    return Semantics(
      selected: selected,
      button: true,
      label: item.label,
      excludeSemantics: true,
      child: InkResponse(
        onTap: onTap,
        radius: 36,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            AnimatedScale(scale: selected ? 1.06 : 1, duration: const Duration(milliseconds: 160), child: icon),
            const SizedBox(height: 3),
            Text(item.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: textTheme.labelSmall?.copyWith(color: fg, letterSpacing: 0, fontSize: 10.5)),
          ]),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Little things
// ---------------------------------------------------------------------------

/// Three bouncing bars that mark the song that is playing; they rest when paused.
class PlayingBars extends StatefulWidget {
  const PlayingBars({super.key, required this.playing, this.color, this.size = 18});

  final bool playing;
  final Color? color;
  final double size;

  @override
  State<PlayingBars> createState() => _PlayingBarsState();
}

class _PlayingBarsState extends State<PlayingBars> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(PlayingBars old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final animate = widget.playing && !(WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.disableAnimations);
    if (animate && !_c.isAnimating) {
      _c.repeat();
    } else if (!animate && _c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).colorScheme.primary;
    return Semantics(
      label: widget.playing ? 'Playing' : 'Paused',
      child: SizedBox.square(
        dimension: widget.size,
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) => CustomPaint(painter: _BarsPainter(_c.value, color, widget.playing)),
        ),
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  _BarsPainter(this.t, this.color, this.playing);

  final double t;
  final Color color;
  final bool playing;

  static const _phases = [0.0, 0.35, 0.7];
  static const _rest = [0.45, 0.8, 0.6];

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final w = size.width / 5;
    for (var i = 0; i < 3; i++) {
      final f = playing ? 0.3 + 0.7 * (0.5 + 0.5 * math.sin(2 * math.pi * (t * (1 + i * 0.37) + _phases[i]))) : _rest[i];
      final h = size.height * f;
      final x = i * 2 * w;
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, size.height - h, w * 1.1, h), Radius.circular(w / 2)), paint);
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) => old.t != t || old.color != color || old.playing != playing;
}

/// A thin, ink-coloured spinner.
class Loader extends StatelessWidget {
  const Loader({super.key});

  @override
  Widget build(BuildContext context) => Center(
    child: SizedBox.square(
      dimension: 28,
      child: CircularProgressIndicator(strokeWidth: 2, strokeCap: StrokeCap.round, color: Theme.of(context).colorScheme.onSurface, backgroundColor: context.tokens.hairline),
    ),
  );
}

/// Greeting for the time of day.
String greeting([DateTime? now]) {
  final h = (now ?? DateTime.now()).hour;
  if (h < 5) return 'Up late';
  if (h < 12) return 'Good morning';
  if (h < 18) return 'Good afternoon';
  return 'Good evening';
}
