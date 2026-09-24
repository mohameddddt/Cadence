import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/brand.dart';

/// The Cadence mark: a record's grooves opened into a "C", with the beat at its centre.
///
/// Two concentric arcs open to the right (the sound leaving the record) around a solid dot.
/// Drawn on a 100 x 100 grid so the same shape can be exported as an Android vector.
class BrandMarkPainter extends CustomPainter {
  const BrandMarkPainter({this.innerColor = Brand.cream, this.dotColor = Brand.amber, this.mono});

  /// Colour of the inner arc (cream on dark tiles, the text colour on light pages).
  final Color innerColor;
  final Color dotColor;

  /// When set, the whole mark is drawn in this single colour (themed icons, watermarks).
  final Color? mono;

  static const double _outerRadius = 34;
  static const double _innerRadius = 19;
  static const double _dotRadius = 7.5;
  static const double _stroke = 9;
  static const double _gap = 40 * math.pi / 180; // half-opening of the "C", towards the right

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide;
    final u = side / 100;
    final c = Offset(size.width / 2, size.height / 2);
    const start = _gap;
    const sweep = 2 * math.pi - 2 * _gap;

    final outer = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke * u
      ..strokeCap = StrokeCap.round;
    if (mono != null) {
      outer.color = mono!;
    } else {
      outer.shader = Brand.flame.createShader(Rect.fromCenter(center: c, width: 2 * _outerRadius * u, height: 2 * _outerRadius * u));
    }
    canvas.drawArc(Rect.fromCircle(center: c, radius: _outerRadius * u), start, sweep, false, outer);

    final inner = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke * u
      ..strokeCap = StrokeCap.round
      ..color = mono ?? innerColor;
    canvas.drawArc(Rect.fromCircle(center: c, radius: _innerRadius * u), start, sweep, false, inner);

    canvas.drawCircle(c, _dotRadius * u, Paint()..color = mono ?? dotColor);
  }

  @override
  bool shouldRepaint(BrandMarkPainter old) => old.innerColor != innerColor || old.dotColor != dotColor || old.mono != mono;
}

/// The bare mark at [size].
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 48, this.innerColor, this.mono});

  final double size;
  final Color? innerColor;
  final Color? mono;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: Brand.name,
      image: true,
      child: CustomPaint(
        size: Size.square(size),
        painter: BrandMarkPainter(innerColor: innerColor ?? Theme.of(context).colorScheme.onSurface, mono: mono),
      ),
    );
  }
}

/// The mark on its night-sky tile: the launcher icon, as a widget.
class BrandTile extends StatelessWidget {
  const BrandTile({super.key, this.size = 72, this.markScale = 0.78});

  final double size;
  final double markScale;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: Brand.name,
      image: true,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: Brand.night,
          borderRadius: BorderRadius.circular(size * 0.30),
          boxShadow: [BoxShadow(color: Brand.coral.withValues(alpha: 0.28), blurRadius: size * 0.35, offset: Offset(0, size * 0.1))],
        ),
        child: CustomPaint(size: Size.square(size * markScale), painter: const BrandMarkPainter()),
      ),
    );
  }
}

/// Mark + lowercase wordmark on one line, for app bars and headers.
class BrandLockup extends StatelessWidget {
  const BrandLockup({super.key, this.markSize = 28, this.fontSize = 22});

  final double markSize;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        BrandMark(size: markSize),
        SizedBox(width: markSize * 0.32),
        Text(
          Brand.name.toLowerCase(),
          style: TextStyle(
            fontFamily: Brand.fontFamily,
            fontVariations: const [FontVariation.weight(700)],
            fontWeight: FontWeight.w700,
            fontSize: fontSize,
            letterSpacing: -0.6,
            color: t.colorScheme.onSurface,
          ),
        ),
      ],
    );
  }
}
