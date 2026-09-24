import 'dart:math' as math;
import 'dart:typed_data';

/// Deterministic, harmonically rich "melody" for audio-algorithm tests.
///
/// Pure function of its arguments so the golden fingerprints stored under
/// test/fixtures stay valid across machines.
Float64List synthMelody({int seconds = 15, int rate = 44100, int seed = 1, double noise = 0.02}) {
  const notes = [0, 4, 7, 12, 9, 5, 2, 11, 7, 3, 0, 8];
  final n = seconds * rate;
  final out = Float64List(n);
  var state = seed;
  double rnd() {
    state = (state * 1103515245 + 12345) & 0x7FFFFFFF;
    return state / 0x7FFFFFFF * 2 - 1;
  }

  for (var i = 0; i < n; i++) {
    final t = i / rate;
    final step = (t * 3).floor(); // three notes a second
    final semis = notes[step % notes.length] + (step ~/ notes.length) * 2;
    final f = 220.0 * math.pow(2, semis / 12.0);
    final env = 0.6 + 0.4 * math.sin(2 * math.pi * (t * 3 % 1) * 0.5);
    var s = 0.0;
    for (var h = 1; h <= 4; h++) {
      s += math.sin(2 * math.pi * f * h * t) / h;
    }
    out[i] = (s * env * 0.25 + rnd() * noise) * 32767 * 0.8;
  }
  return out;
}

/// Quantises to 16-bit like a real decoder would.
Int16List toInt16(Float64List x) => Int16List.fromList([for (final v in x) v.round().clamp(-32768, 32767)]);

Uint8List wavBytes(Int16List pcm, int rate) {
  final data = pcm.buffer.asUint8List(pcm.offsetInBytes, pcm.lengthInBytes);
  final b = BytesBuilder();
  void str(String s) => b.add(s.codeUnits);
  void u32(int v) => b.add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
  void u16(int v) => b.add((ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List());
  str('RIFF');
  u32(36 + data.length);
  str('WAVEfmt ');
  u32(16);
  u16(1);
  u16(1);
  u32(rate);
  u32(rate * 2);
  u16(2);
  u16(16);
  str('data');
  u32(data.length);
  b.add(data);
  return b.toBytes();
}
