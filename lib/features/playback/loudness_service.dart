import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../../core/library/library_repository.dart';
import '../../core/models/track.dart';
import '../../platform/bridges.dart';
import '../metadata/tag_writer.dart';
import 'loudness.dart';

class LoudnessResult {
  const LoudnessResult({required this.lufs, required this.gainDb, required this.peak});
  final double lufs;
  final double gainDb;
  final double peak;
}

/// Measures track loudness (EBU R128) and stores it as ReplayGain 2.0 in the tags + DB.
class LoudnessService {
  LoudnessService({required this.repo, required this.decoder, required this.tagWriter, required this.tempDir});

  final LibraryRepository repo;
  final DecoderBridge decoder;
  final TagWriter tagWriter;
  final Directory Function() tempDir;

  Future<LoudnessResult?> measure(Track t) async {
    final dir = tempDir()..createSync(recursive: true);
    final out = File('${dir.path}/rg_${t.id}_${DateTime.now().microsecondsSinceEpoch}.pcm');
    try {
      final info = await decoder.decode(
        path: t.hasRealPath ? t.filePath : null,
        uri: t.contentUri,
        out: out.path,
        sampleRate: 0,
        channels: 2,
        maxSeconds: 0,
      );
      if (info.frames < info.sampleRate * 2) return null;
      final path = out.path;
      final rate = info.sampleRate;
      final ch = info.channels;
      final r = await Isolate.run(() => analyzePcmFile(path, rate, ch));
      if (r == null) return null;
      return LoudnessResult(lufs: r.$1, gainDb: r.$2, peak: r.$3);
    } finally {
      if (out.existsSync()) out.deleteSync();
    }
  }

  /// Measures and stores REPLAYGAIN_TRACK_GAIN. Returns the gain in dB.
  Future<double?> analyzeAndStore(Track t, {bool writeTags = true}) async {
    final r = await measure(t);
    if (r == null) return null;
    await repo.updateTrackColumns(t.id, {'replay_gain_track': r.gainDb});
    if (writeTags) {
      await tagWriter.write(t, TagUpdate({'replayGainTrack': LoudnessAnalyzer.formatGain(r.gainDb)}));
    }
    return r.gainDb;
  }

  /// Every track that has no ReplayGain yet (batch job from the settings screen).
  Stream<({int done, int total})> analyzeMissing({bool Function()? isCancelled}) async* {
    final all = await repo.tracks();
    final todo = all.where((t) => t.replayGainTrack == null).toList();
    for (var i = 0; i < todo.length; i++) {
      if (isCancelled?.call() ?? false) break;
      yield (done: i, total: todo.length);
      try {
        await analyzeAndStore(todo[i]);
      } on Exception {
        continue;
      }
    }
    yield (done: todo.length, total: todo.length);
  }
}

/// Reads a raw s16le PCM file in chunks (isolate entry point). Returns (LUFS, gain, peak).
(double, double, double)? analyzePcmFile(String path, int rate, int channels) {
  final analyzer = LoudnessAnalyzer(sampleRate: rate, channels: channels);
  final raf = File(path).openSync();
  try {
    final chunkBytes = 2 * channels * 8192;
    final buf = Uint8List(chunkBytes);
    while (true) {
      final n = raf.readIntoSync(buf);
      if (n <= 0) break;
      final usable = n - (n % (2 * channels));
      if (usable <= 0) break;
      final samples = Int16List.sublistView(Uint8List.fromList(buf.sublist(0, usable)));
      analyzer.addInterleaved(samples);
    }
  } finally {
    raf.closeSync();
  }
  final l = analyzer.integratedLufs;
  if (l == null) return null;
  return (l, -18.0 - l, analyzer.samplePeak);
}
