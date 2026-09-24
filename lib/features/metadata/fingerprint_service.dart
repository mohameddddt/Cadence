import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../../core/models/track.dart';
import '../../platform/bridges.dart';
import 'chromaprint.dart';

class Fingerprint {
  const Fingerprint({required this.encoded, required this.durationSeconds, required this.raw});

  /// Compressed, URL-safe base64 as expected by AcoustID.
  final String encoded;
  final int durationSeconds;
  final List<int> raw;
}

/// Decodes a file natively (MediaCodec) and fingerprints its first two minutes in Dart.
class FingerprintService {
  FingerprintService({required this.decoder, required this.tempDir});

  final DecoderBridge decoder;

  /// Directory for the temporary PCM file (cache dir).
  final Directory Function() tempDir;

  Future<Fingerprint?> forTrack(Track t) async {
    final dir = tempDir()..createSync(recursive: true);
    final out = File('${dir.path}/fp_${t.id}_${DateTime.now().microsecondsSinceEpoch}.pcm');
    try {
      final info = await decoder.decode(
        path: t.hasRealPath ? t.filePath : null,
        uri: t.contentUri,
        out: out.path,
        sampleRate: 0, // native rate; Dart low-passes and resamples properly
        channels: 1,
        maxSeconds: 120,
      );
      if (info.frames < info.sampleRate * 8) return null; // under 8 s is too short to identify
      final bytes = await out.readAsBytes();
      final rate = info.sampleRate;
      final raw = await Isolate.run(() => Chromaprint.fingerprintPcm16(Uint8List.fromList(bytes), rate));
      if (raw.isEmpty) return null;
      final seconds = t.durationMs > 0 ? (t.durationMs / 1000).round() : (info.frames / info.sampleRate).round();
      return Fingerprint(encoded: Chromaprint.encode(raw), durationSeconds: seconds, raw: raw);
    } finally {
      if (out.existsSync()) out.deleteSync();
    }
  }
}
