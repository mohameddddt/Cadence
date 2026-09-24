import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/core/audio/resampler.dart';
import 'package:musicplayer/features/metadata/chromaprint.dart';

import 'helpers/synth.dart';

void main() {
  final reference = File('test/fixtures/synth_melody_fpcalc.txt')
      .readAsStringSync()
      .trim()
      .split(',')
      .map((e) => int.parse(e) & 0xFFFFFFFF)
      .toList();
  final pcm = toInt16(synthMelody());

  List<int> fp(Int16List samples, {int rate = 44100}) =>
      Chromaprint.fingerprintPcm16(samples.buffer.asUint8List(samples.offsetInBytes, samples.lengthInBytes), rate);

  test('matches the reference fpcalc (1.5.1) output for a synthetic melody', () {
    final mine = fp(pcm);
    expect(mine.length, reference.length);
    expect(Chromaprint.similarity(mine, reference), greaterThan(0.995));
  });

  test('is deterministic', () {
    expect(fp(pcm), fp(pcm));
  });

  test('a lightly degraded copy stays close, different music does not', () {
    final noisy = toInt16(synthMelody(noise: 0.08));
    final other = toInt16(Float64List.fromList(synthMelody(seed: 7).reversed.toList()));
    final a = fp(pcm);
    expect(Chromaprint.similarity(a, fp(noisy)), greaterThan(0.80));
    expect(Chromaprint.similarity(a, fp(other)), lessThan(0.75));
  });

  test('resampling to another input rate keeps the fingerprint close (48 kHz)', () {
    final at48 = toInt16(Resampler.resample(synthMelody(), 44100, 48000));
    expect(Chromaprint.similarity(fp(at48, rate: 48000), fp(pcm)), greaterThan(0.85));
  });

  test('compress/decompress round-trips exactly, and matches the documented layout', () {
    final encoded = Chromaprint.encode(reference);
    expect(Chromaprint.decode(encoded), reference);
    // first byte = algorithm 1 (TEST2), next three = length
    final raw = base64Url.decode(encoded.padRight((encoded.length + 3) ~/ 4 * 4, '='));
    expect(raw[0], 1);
    expect((raw[1] << 16) | (raw[2] << 8) | raw[3], reference.length);
    expect(encoded.contains('='), isFalse);
    expect(encoded.contains('+') || encoded.contains('/'), isFalse, reason: 'URL-safe alphabet');
  });

  test('empty and too-short input produce no sub-fingerprints', () {
    expect(Chromaprint.fingerprint(Float64List(0), 44100), isEmpty);
    expect(Chromaprint.fingerprint(Float64List(3000), 11025), isEmpty);
    expect(Chromaprint.encode(const []), isNotEmpty);
  });

  test('silence yields all-equal sub-fingerprints', () {
    final silent = fp(Int16List(44100 * 8));
    expect(silent.toSet().length, 1);
  });

  test('only the first 120 seconds are used', () {
    final long = Float64List(44100 * 130);
    expect(Chromaprint.fingerprint(long, 44100).length, lessThanOrEqualTo(120 * 11025 ~/ 1365));
  });
}
