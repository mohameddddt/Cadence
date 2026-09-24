import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/features/playback/loudness.dart';

Int16List sine({required int rate, required double seconds, required double amplitude, double freq = 997, int channels = 1}) {
  final n = (rate * seconds).round();
  final out = Int16List(n * channels);
  for (var i = 0; i < n; i++) {
    final v = (math.sin(2 * math.pi * freq * i / rate) * amplitude * 32767).round();
    for (var c = 0; c < channels; c++) {
      out[i * channels + c] = v;
    }
  }
  return out;
}

double? lufsOf(List<Int16List> parts, {required int rate, int channels = 1}) {
  final a = LoudnessAnalyzer(sampleRate: rate, channels: channels);
  for (final p in parts) {
    a.addInterleaved(p);
  }
  return a.integratedLufs;
}

void main() {
  group('BS.1770 reference points', () {
    test('997 Hz mono sine at -20 dBFS peak measures -23.0 LUFS (44.1 kHz)', () {
      final l = lufsOf([sine(rate: 44100, seconds: 10, amplitude: 0.1)], rate: 44100)!;
      expect(l, closeTo(-23.0, 0.1));
    });

    test('same at 48 kHz - filters are designed per sample rate', () {
      final l = lufsOf([sine(rate: 48000, seconds: 10, amplitude: 0.1)], rate: 48000)!;
      expect(l, closeTo(-23.0, 0.1));
    });

    test('full-scale 997 Hz sine measures -3.01 LUFS', () {
      final l = lufsOf([sine(rate: 48000, seconds: 5, amplitude: 1.0)], rate: 48000)!;
      expect(l, closeTo(-3.01, 0.1));
    });

    test('halving the amplitude lowers loudness by 6.02 LU', () {
      final loud = lufsOf([sine(rate: 44100, seconds: 6, amplitude: 0.5)], rate: 44100)!;
      final quiet = lufsOf([sine(rate: 44100, seconds: 6, amplitude: 0.25)], rate: 44100)!;
      expect(loud - quiet, closeTo(6.02, 0.05));
    });

    test('identical stereo channels are 3 LU louder than one channel', () {
      final mono = lufsOf([sine(rate: 44100, seconds: 6, amplitude: 0.1)], rate: 44100)!;
      final stereo = lufsOf([sine(rate: 44100, seconds: 6, amplitude: 0.1, channels: 2)], rate: 44100, channels: 2)!;
      expect(stereo - mono, closeTo(3.01, 0.05));
    });

    test('K-weighting attenuates very low frequencies', () {
      final low = lufsOf([sine(rate: 48000, seconds: 8, amplitude: 0.3, freq: 30)], rate: 48000)!;
      final mid = lufsOf([sine(rate: 48000, seconds: 8, amplitude: 0.3, freq: 997)], rate: 48000)!;
      expect(mid - low, greaterThan(3));
    });
  });

  group('gating', () {
    test('digital silence is ignored by the absolute gate', () {
      final tone = sine(rate: 44100, seconds: 6, amplitude: 0.1);
      final silence = Int16List(44100 * 30);
      expect(lufsOf([tone, silence], rate: 44100)!, closeTo(-23.0, 0.15));
    });

    test('a passage 20 LU quieter is removed by the relative gate', () {
      final loud = sine(rate: 44100, seconds: 10, amplitude: 0.1);
      final quiet = sine(rate: 44100, seconds: 30, amplitude: 0.01);
      expect(lufsOf([loud, quiet], rate: 44100)!, closeTo(-23.0, 0.3));
    });

    test('pure silence or too little audio is null, not -infinity', () {
      expect(lufsOf([Int16List(44100 * 5)], rate: 44100), isNull);
      expect(lufsOf([sine(rate: 44100, seconds: 0.2, amplitude: 0.1)], rate: 44100), isNull);
    });
  });

  test('chunked input gives the same answer as a single buffer', () {
    final all = sine(rate: 44100, seconds: 8, amplitude: 0.2);
    final whole = lufsOf([all], rate: 44100)!;
    final chunks = <Int16List>[];
    for (var i = 0; i < all.length; i += 12345) {
      chunks.add(Int16List.sublistView(all, i, math.min(all.length, i + 12345)));
    }
    expect(lufsOf(chunks, rate: 44100)!, closeTo(whole, 1e-9));
  });

  test('ReplayGain 2.0 gain targets -18 LUFS', () {
    final a = LoudnessAnalyzer(sampleRate: 44100, channels: 1)..addInterleaved(sine(rate: 44100, seconds: 8, amplitude: 0.1));
    expect(a.replayGainDb!, closeTo(5.0, 0.1)); // -18 - (-23)
    expect(a.samplePeak, closeTo(0.1, 0.001));
  });

  test('gain string formatting and parsing', () {
    expect(LoudnessAnalyzer.formatGain(-3.2), '-3.20 dB');
    expect(LoudnessAnalyzer.formatGain(1.5), '+1.50 dB');
    expect(LoudnessAnalyzer.parseGain('-3.20 dB'), -3.2);
    expect(LoudnessAnalyzer.parseGain('+1,5dB'), 1.5);
    expect(LoudnessAnalyzer.parseGain('n/a'), isNull);
    expect(LoudnessAnalyzer.parseGain(null), isNull);
  });
}
