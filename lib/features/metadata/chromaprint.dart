import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../core/audio/resampler.dart';

/// Pure-Dart port of the Chromaprint (AcoustID) fingerprinting algorithm, "TEST2"
/// configuration - the one `fpcalc` and the AcoustID web service use by default.
///
/// Pipeline: mono 11025 Hz audio -> 4096-sample Hamming-windowed FFT frames with a
/// 1365-sample hop -> 12-band chroma energy (28-3520 Hz) -> 5-tap smoothing over time
/// -> L2 normalisation -> 16 filter/quantiser classifiers over a summed-area table
/// -> one 32-bit sub-fingerprint per frame.
///
/// Original algorithm and constants: Lukas Lalinsky, MIT licence.
class Chromaprint {
  const Chromaprint._();

  /// Value stored in the first byte of compressed fingerprints.
  static const int algorithm = 1; // CHROMAPRINT_ALGORITHM_TEST2

  static const int sampleRate = 11025;
  static const int frameSize = 4096;
  static const int hop = frameSize - (frameSize - frameSize ~/ 3); // 1365
  static const int minFreq = 28;
  static const int maxFreq = 3520;
  static const int bands = 12;
  static const List<double> _filterCoefficients = [0.25, 0.75, 1.0, 0.75, 0.25];

  // Filter(type, y, height, width) + Quantizer(t0, t1, t2)
  static const List<_Classifier> _classifiers = [
    _Classifier(0, 4, 3, 15, 1.98215, 2.35817, 2.63523),
    _Classifier(4, 4, 6, 15, -1.03809, -0.651211, -0.282167),
    _Classifier(1, 0, 4, 16, -0.298702, 0.119262, 0.558497),
    _Classifier(3, 8, 2, 12, -0.105439, 0.0153946, 0.135898),
    _Classifier(3, 4, 4, 8, -0.142891, 0.0258736, 0.200632),
    _Classifier(4, 0, 3, 5, -0.826319, -0.590612, -0.368214),
    _Classifier(1, 2, 2, 9, -0.557409, -0.233035, 0.0534525),
    _Classifier(2, 7, 3, 4, -0.0646826, 0.00620476, 0.0784847),
    _Classifier(2, 6, 2, 16, -0.192387, -0.029699, 0.215855),
    _Classifier(2, 1, 3, 2, -0.0397818, -0.00568076, 0.0292026),
    _Classifier(5, 10, 1, 15, -0.53823, -0.369934, -0.190235),
    _Classifier(3, 6, 2, 10, -0.124877, 0.0296483, 0.139239),
    _Classifier(2, 1, 1, 14, -0.101475, 0.0225617, 0.231971),
    _Classifier(3, 5, 6, 4, -0.0799915, -0.00729616, 0.063262),
    _Classifier(1, 9, 2, 12, -0.272556, 0.019424, 0.302559),
    _Classifier(3, 4, 2, 14, -0.164292, -0.0321188, 0.0846339),
  ];

  static const List<int> _gray = [0, 1, 3, 2];

  /// Fingerprint of mono [samples] (16-bit range values, any sample rate). At most
  /// [maxSeconds] of audio are used, like `fpcalc -length` (default 120 s).
  static List<int> fingerprint(Float64List samples, int inputRate, {int maxSeconds = 120}) {
    final limited = samples.length > inputRate * maxSeconds ? Float64List.sublistView(samples, 0, inputRate * maxSeconds) : samples;
    final pcm = inputRate == sampleRate ? limited : Resampler.resample(limited, inputRate, sampleRate);
    return _fingerprint11k(pcm);
  }

  /// Convenience for raw signed 16-bit little-endian PCM.
  static List<int> fingerprintPcm16(Uint8List bytes, int inputRate, {int channels = 1, int maxSeconds = 120}) {
    final view = ByteData.sublistView(bytes);
    final frames = bytes.length ~/ (2 * channels);
    final mono = Float64List(frames);
    for (var i = 0; i < frames; i++) {
      var sum = 0;
      for (var c = 0; c < channels; c++) {
        sum += view.getInt16((i * channels + c) * 2, Endian.little);
      }
      mono[i] = (sum ~/ channels).toDouble(); // integer average like Chromaprint
    }
    return fingerprint(mono, inputRate, maxSeconds: maxSeconds);
  }

  static List<int> _fingerprint11k(Float64List pcm) {
    // --- FFT + chroma -------------------------------------------------------
    final window = Float64List(frameSize);
    for (var i = 0; i < frameSize; i++) {
      window[i] = (0.54 - 0.46 * math.cos(i * 2.0 * math.pi / (frameSize - 1))) / 32767.0;
    }
    final minIndex = math.max(1, (frameSize * minFreq / sampleRate).round());
    final maxIndex = math.min(frameSize ~/ 2, (frameSize * maxFreq / sampleRate).round());
    final notes = Int32List(frameSize ~/ 2 + 1);
    for (var i = minIndex; i < maxIndex; i++) {
      final freq = i * sampleRate / frameSize;
      final octave = math.log(freq / (440.0 / 16.0)) / math.ln2;
      final note = bands * (octave - octave.floorToDouble());
      notes[i] = note.truncate();
    }

    final fft = _Fft(frameSize);
    final re = Float64List(frameSize);
    final im = Float64List(frameSize);

    final chromaRows = <Float64List>[];
    for (var start = 0; start + frameSize <= pcm.length; start += hop) {
      for (var i = 0; i < frameSize; i++) {
        re[i] = pcm[start + i] * window[i];
        im[i] = 0;
      }
      fft.transform(re, im);
      final features = Float64List(bands);
      for (var i = minIndex; i < maxIndex; i++) {
        features[notes[i]] += re[i] * re[i] + im[i] * im[i];
      }
      chromaRows.add(features);
    }

    // --- smoothing over time, then normalisation --------------------------------
    final n = _filterCoefficients.length;
    final rows = <Float64List>[];
    for (var t = n - 1; t < chromaRows.length; t++) {
      final out = Float64List(bands);
      for (var b = 0; b < bands; b++) {
        var acc = 0.0;
        for (var j = 0; j < n; j++) {
          acc += chromaRows[t - n + 1 + j][b] * _filterCoefficients[j];
        }
        out[b] = acc;
      }
      var squares = 0.0;
      for (final v in out) {
        squares += v * v;
      }
      final norm = squares > 0 ? math.sqrt(squares) : 0.0;
      if (norm < 0.01) {
        out.fillRange(0, bands, 0.0);
      } else {
        for (var b = 0; b < bands; b++) {
          out[b] /= norm;
        }
      }
      rows.add(out);
    }

    // --- summed-area table (rows = time, columns = chroma bands) ---------------
    final table = List<Float64List>.generate(rows.length, (_) => Float64List(bands));
    for (var r = 0; r < rows.length; r++) {
      var rowSum = 0.0;
      for (var c = 0; c < bands; c++) {
        rowSum += rows[r][c];
        table[r][c] = rowSum + (r > 0 ? table[r - 1][c] : 0.0);
      }
    }

    double area(int r1, int c1, int r2, int c2) {
      if (r1 == r2 || c1 == c2) return 0.0;
      if (r1 == 0) {
        final row = table[r2 - 1];
        return c1 == 0 ? row[c2 - 1] : row[c2 - 1] - row[c1 - 1];
      }
      final row1 = table[r1 - 1];
      final row2 = table[r2 - 1];
      return c1 == 0 ? row2[c2 - 1] - row1[c2 - 1] : row2[c2 - 1] - row1[c2 - 1] - row2[c1 - 1] + row1[c1 - 1];
    }

    // --- classifiers -------------------------------------------------------------
    final maxWidth = _classifiers.map((c) => c.width).reduce(math.max);
    final fp = <int>[];
    for (var offset = 0; offset + maxWidth <= rows.length; offset++) {
      var bits = 0;
      for (final c in _classifiers) {
        bits = ((bits << 2) | _gray[c.classify(area, offset)]) & 0xFFFFFFFF;
      }
      fp.add(bits);
    }
    return fp;
  }

  // ------------------------------------------------------------ compression

  /// Compressed, URL-safe base64 form used by the AcoustID web service.
  static String encode(List<int> fp, {int algorithm = Chromaprint.algorithm}) {
    final normal = <int>[];
    final exceptional = <int>[];

    void process(int x) {
      var bit = 1, last = 0;
      var v = x;
      while (v != 0) {
        if ((v & 1) != 0) {
          final value = bit - last;
          if (value >= 7) {
            normal.add(7);
            exceptional.add(value - 7);
          } else {
            normal.add(value);
          }
          last = bit;
        }
        v >>= 1;
        bit++;
      }
      normal.add(0);
    }

    if (fp.isNotEmpty) {
      process(fp[0]);
      for (var i = 1; i < fp.length; i++) {
        process((fp[i] ^ fp[i - 1]) & 0xFFFFFFFF);
      }
    }
    final bytes = <int>[
      algorithm & 255,
      (fp.length >> 16) & 255,
      (fp.length >> 8) & 255,
      fp.length & 255,
      ..._packBits(normal, 3),
      ..._packBits(exceptional, 5),
    ];
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// Inverse of [encode] (used in tests and for debugging).
  static List<int> decode(String text) {
    var s = text;
    while (s.length % 4 != 0) {
      s += '=';
    }
    final bytes = base64Url.decode(s);
    final count = (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
    final body = Uint8List.sublistView(Uint8List.fromList(bytes), 4);

    int readBits(int n, int at) {
      var v = 0;
      for (var i = 0; i < n; i++) {
        final p = at + i;
        v |= ((body[p >> 3] >> (p & 7)) & 1) << i;
      }
      return v;
    }

    // 3-bit "normal" values: one zero terminates each sub-fingerprint.
    final normal = <int>[];
    var bitPos = 0, zeros = 0;
    while (zeros < count && bitPos + 3 <= body.length * 8) {
      final v = readBits(3, bitPos);
      bitPos += 3;
      normal.add(v);
      if (v == 0) zeros++;
    }
    // 5-bit "exceptional" values follow, byte aligned.
    var exPos = ((normal.length * 3 + 7) ~/ 8) * 8;
    final out = <int>[];
    var acc = 0, bit = 0;
    for (final v in normal) {
      if (v == 0) {
        out.add(out.isEmpty ? acc : (acc ^ out.last) & 0xFFFFFFFF);
        acc = 0;
        bit = 0;
        continue;
      }
      var value = v;
      if (v == 7) {
        value += readBits(5, exPos);
        exPos += 5;
      }
      bit += value;
      acc |= 1 << (bit - 1);
    }
    return out;
  }

  static List<int> _packBits(List<int> values, int width) {
    final out = <int>[];
    var acc = 0, nbits = 0;
    for (final v in values) {
      acc |= (v & ((1 << width) - 1)) << nbits;
      nbits += width;
      while (nbits >= 8) {
        out.add(acc & 0xFF);
        acc >>= 8;
        nbits -= 8;
      }
    }
    if (nbits > 0) out.add(acc & 0xFF);
    return out;
  }

  /// Number of differing bits between two sub-fingerprints.
  static int hamming(int a, int b) {
    var x = (a ^ b) & 0xFFFFFFFF;
    var c = 0;
    while (x != 0) {
      c += x & 1;
      x >>= 1;
    }
    return c;
  }

  /// Fraction of matching bits over the common prefix, 1.0 = identical.
  static double similarity(List<int> a, List<int> b) {
    final n = math.min(a.length, b.length);
    if (n == 0) return 0;
    var diff = 0;
    for (var i = 0; i < n; i++) {
      diff += hamming(a[i], b[i]);
    }
    return 1 - diff / (n * 32);
  }
}

class _Classifier {
  const _Classifier(this.type, this.y, this.height, this.width, this.t0, this.t1, this.t2);

  final int type;
  final int y;
  final int height;
  final int width;
  final double t0, t1, t2;

  int classify(double Function(int r1, int c1, int r2, int c2) area, int x) {
    final v = _apply(area, x);
    if (v < t1) return v < t0 ? 0 : 1;
    return v < t2 ? 2 : 3;
  }

  static double _subtractLog(double a, double b) => math.log((1.0 + a) / (1.0 + b));

  double _apply(double Function(int, int, int, int) area, int x) {
    final w = width, h = height;
    switch (type) {
      case 0:
        return _subtractLog(area(x, y, x + w, y + h), 0);
      case 1:
        final h2 = h ~/ 2;
        return _subtractLog(area(x, y + h2, x + w, y + h), area(x, y, x + w, y + h2));
      case 2:
        final w2 = w ~/ 2;
        return _subtractLog(area(x + w2, y, x + w, y + h), area(x, y, x + w2, y + h));
      case 3:
        final w2 = w ~/ 2, h2 = h ~/ 2;
        final a = area(x, y + h2, x + w2, y + h) + area(x + w2, y, x + w, y + h2);
        final b = area(x, y, x + w2, y + h2) + area(x + w2, y + h2, x + w, y + h);
        return _subtractLog(a, b);
      case 4:
        final h3 = h ~/ 3;
        final a = area(x, y + h3, x + w, y + 2 * h3);
        final b = area(x, y, x + w, y + h3) + area(x, y + 2 * h3, x + w, y + h);
        return _subtractLog(a, b);
      case 5:
        final w3 = w ~/ 3;
        final a = area(x + w3, y, x + 2 * w3, y + h);
        final b = area(x, y, x + w3, y + h) + area(x + 2 * w3, y, x + w, y + h);
        return _subtractLog(a, b);
    }
    return 0;
  }
}

/// In-place radix-2 complex FFT.
class _Fft {
  _Fft(this.n)
      : _cos = Float64List(n ~/ 2),
        _sin = Float64List(n ~/ 2),
        _rev = Int32List(n) {
    for (var i = 0; i < n ~/ 2; i++) {
      _cos[i] = math.cos(2 * math.pi * i / n);
      _sin[i] = -math.sin(2 * math.pi * i / n);
    }
    final bits = (math.log(n) / math.ln2).round();
    for (var i = 0; i < n; i++) {
      var r = 0, x = i;
      for (var b = 0; b < bits; b++) {
        r = (r << 1) | (x & 1);
        x >>= 1;
      }
      _rev[i] = r;
    }
  }

  final int n;
  final Float64List _cos, _sin;
  final Int32List _rev;

  void transform(Float64List re, Float64List im) {
    for (var i = 0; i < n; i++) {
      final j = _rev[i];
      if (j > i) {
        final tr = re[i];
        re[i] = re[j];
        re[j] = tr;
        final ti = im[i];
        im[i] = im[j];
        im[j] = ti;
      }
    }
    for (var size = 2; size <= n; size <<= 1) {
      final half = size >> 1;
      final step = n ~/ size;
      for (var start = 0; start < n; start += size) {
        var k = 0;
        for (var j = start; j < start + half; j++) {
          final l = j + half;
          final tr = re[l] * _cos[k] - im[l] * _sin[k];
          final ti = re[l] * _sin[k] + im[l] * _cos[k];
          re[l] = re[j] - tr;
          im[l] = im[j] - ti;
          re[j] += tr;
          im[j] += ti;
          k += step;
        }
      }
    }
  }
}
