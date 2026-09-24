import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Cover-art preparation: centre-crop to a square, limit the size, re-encode as JPEG.
///
/// Wide YouTube thumbnails (16:9) look wrong as album art, and embedding huge images
/// bloats files (some car stereos refuse anything above ~1200 px).
class ImageProcessing {
  const ImageProcessing._();

  static const int maxEmbedSize = 1200;

  /// Runs [processCover] in a background isolate.
  static Future<Uint8List> processCoverAsync(Uint8List bytes, {int maxSize = maxEmbedSize, int quality = 90}) =>
      Isolate.run(() => processCover(bytes, maxSize: maxSize, quality: quality));

  /// Square, at most [maxSize] px, JPEG. Throws [FormatException] for unreadable data.
  static Uint8List processCover(Uint8List bytes, {int maxSize = maxEmbedSize, int quality = 90}) {
    img.Image? decoded;
    try {
      decoded = img.decodeImage(bytes);
    } on Object {
      decoded = null; // the decoders throw assorted errors on truncated/garbage data
    }
    if (decoded == null) throw const FormatException('Not a decodable image');
    final side = decoded.width < decoded.height ? decoded.width : decoded.height;
    final x = (decoded.width - side) ~/ 2;
    final y = (decoded.height - side) ~/ 2;
    var square = (decoded.width == decoded.height) ? decoded : img.copyCrop(decoded, x: x, y: y, width: side, height: side);
    if (square.width > maxSize) {
      square = img.copyResize(square, width: maxSize, height: maxSize, interpolation: img.Interpolation.average);
    }
    return Uint8List.fromList(img.encodeJpg(square, quality: quality));
  }

  /// Width/height without a full decode where possible.
  static ({int width, int height})? dimensions(Uint8List bytes) {
    final d = img.decodeImage(bytes);
    return d == null ? null : (width: d.width, height: d.height);
  }

  /// Dominant-ish colour of [bytes] (average of a tiny thumbnail), as 0xAARRGGBB.
  /// Cheap fallback for places where Flutter's ColorScheme.fromImageProvider is overkill.
  static int? averageColor(Uint8List bytes) {
    final d = img.decodeImage(bytes);
    if (d == null) return null;
    final t = img.copyResize(d, width: 8, height: 8, interpolation: img.Interpolation.average);
    var r = 0, g = 0, b = 0;
    for (final p in t) {
      r += p.r.toInt();
      g += p.g.toInt();
      b += p.b.toInt();
    }
    final n = t.width * t.height;
    return 0xFF000000 | ((r ~/ n) << 16) | ((g ~/ n) << 8) | (b ~/ n);
  }
}
