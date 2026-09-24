// Renders the Cadence icon set from the in-app painter so the logo has one source of truth.
//
// Run on demand (it is deliberately outside test/ so `flutter test` skips it):
//   flutter test tool/generate_brand_assets_test.dart
//
// Writes: assets/brand/icon_1024.png, android legacy mipmaps, web icons + favicon.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/app/brand.dart';
import 'package:musicplayer/ui/widgets/brand_logo.dart';

Future<void> _render(String path, int size, {required double corner, double markScale = 0.73}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final s = size.toDouble();
  final rect = Rect.fromLTWH(0, 0, s, s);
  canvas.save();
  if (corner > 0) canvas.clipRRect(RRect.fromRectAndRadius(rect, Radius.circular(s * corner)));
  canvas.drawRect(rect, Paint()..shader = Brand.night.createShader(rect));
  // a soft coral glow under the mark gives the flat tile some depth
  canvas.drawCircle(
    Offset(s / 2, s / 2),
    s * 0.42,
    Paint()
      ..shader = ui.Gradient.radial(Offset(s / 2, s / 2), s * 0.42, [Brand.coral.withValues(alpha: 0.22), Brand.coral.withValues(alpha: 0)]),
  );
  final m = s * markScale;
  canvas.save();
  canvas.translate((s - m) / 2, (s - m) / 2);
  const BrandMarkPainter().paint(canvas, Size.square(m));
  canvas.restore();
  canvas.restore();
  final image = await recorder.endRecording().toImage(size, size);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File(path)..parent.createSync(recursive: true);
  file.writeAsBytesSync(data!.buffer.asUint8List());
}

void main() {
  testWidgets('generate brand assets', (tester) async {
    await tester.runAsync(() async {
      await _render('assets/brand/icon_1024.png', 1024, corner: 0.22);
      const legacy = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192};
      for (final e in legacy.entries) {
        await _render('android/app/src/main/res/mipmap-${e.key}/ic_launcher.png', e.value, corner: 0.22);
      }
      await _render('web/icons/Icon-192.png', 192, corner: 0.22);
      await _render('web/icons/Icon-512.png', 512, corner: 0.22);
      await _render('web/icons/Icon-maskable-192.png', 192, corner: 0, markScale: 0.66);
      await _render('web/icons/Icon-maskable-512.png', 512, corner: 0, markScale: 0.66);
      await _render('web/favicon.png', 32, corner: 0.22);
    });
  });
}
