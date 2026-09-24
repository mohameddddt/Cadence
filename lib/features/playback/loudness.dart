import 'dart:math' as math;
import 'dart:typed_data';

/// ITU-R BS.1770-4 / EBU R128 integrated loudness, streaming.
///
/// Used to compute ReplayGain 2.0 values (reference level -18 LUFS) for tracks that
/// carry no ReplayGain tags. Filter design follows libebur128's bilinear-transform
/// formulation so it works at any sample rate.
class LoudnessAnalyzer {
  LoudnessAnalyzer({required this.sampleRate, required this.channels})
      : assert(channels >= 1),
        _subBlockLength = (sampleRate * 0.1).round(),
        _stages = List.generate(channels, (_) => _KWeighting(sampleRate)),
        _weights = _channelWeights(channels);

  final int sampleRate;
  final int channels;
  final int _subBlockLength;
  final List<_KWeighting> _stages;
  final List<double> _weights;

  /// Sum of channel-weighted squares per completed 100 ms sub-block.
  final List<double> _subBlocks = [];
  final List<double> _subAcc = [];
  int _subCount = 0;
  double _peak = 0;

  // BS.1770 channel weights: L, R, C = 1.0; Ls, Rs = 1.41; LFE ignored (5.1 order assumed).
  static List<double> _channelWeights(int n) {
    if (n == 6) return const [1, 1, 1, 0, 1.41, 1.41];
    if (n == 5) return const [1, 1, 1, 1.41, 1.41];
    return List<double>.filled(n, 1.0);
  }

  /// Feed interleaved 16-bit samples.
  void addInterleaved(Int16List samples) {
    final frames = samples.length ~/ channels;
    if (_subAcc.isEmpty) _subAcc.addAll(List<double>.filled(channels, 0));
    for (var i = 0; i < frames; i++) {
      for (var c = 0; c < channels; c++) {
        final x = samples[i * channels + c] / 32768.0;
        final ax = x.abs();
        if (ax > _peak) _peak = ax;
        final y = _stages[c].process(x);
        _subAcc[c] += y * y;
      }
      _subCount++;
      if (_subCount == _subBlockLength) _closeSubBlock();
    }
  }

  void _closeSubBlock() {
    var z = 0.0;
    for (var c = 0; c < channels; c++) {
      z += _weights[c] * _subAcc[c];
      _subAcc[c] = 0;
    }
    _subBlocks.add(z);
    _subCount = 0;
  }

  /// Highest absolute sample seen, linear (1.0 = full scale).
  double get samplePeak => _peak;

  /// Integrated, gated loudness in LUFS, or null when the material is too short or silent.
  double? get integratedLufs {
    // 400 ms momentary blocks with 75 % overlap = 4 sub-blocks, hop of 1.
    if (_subBlocks.length < 4) return null;
    final blockPower = <double>[];
    final norm = 1.0 / (4 * _subBlockLength);
    for (var i = 0; i + 4 <= _subBlocks.length; i++) {
      final sum = _subBlocks[i] + _subBlocks[i + 1] + _subBlocks[i + 2] + _subBlocks[i + 3];
      blockPower.add(sum * norm);
    }
    double lufs(double z) => -0.691 + 10 * math.log(z) / math.ln10;

    // Absolute gate at -70 LUFS.
    final absGated = [for (final z in blockPower) if (z > 0 && lufs(z) > -70.0) z];
    if (absGated.isEmpty) return null;
    final meanAbs = absGated.reduce((a, b) => a + b) / absGated.length;
    // Relative gate 10 LU below the absolute-gated mean.
    final relThreshold = lufs(meanAbs) - 10.0;
    final relGated = [for (final z in absGated) if (lufs(z) > relThreshold) z];
    if (relGated.isEmpty) return null;
    final mean = relGated.reduce((a, b) => a + b) / relGated.length;
    return lufs(mean);
  }

  /// ReplayGain 2.0 track gain in dB (reference -18 LUFS), or null if unmeasurable.
  double? get replayGainDb {
    final l = integratedLufs;
    return l == null ? null : -18.0 - l;
  }

  static String formatGain(double db) => '${db >= 0 ? '+' : ''}${db.toStringAsFixed(2)} dB';

  /// Parses "-3.20 dB", "+1.5dB", "-3.2".
  static double? parseGain(String? s) {
    if (s == null) return null;
    final m = RegExp(r'[-+]?\d+(?:[.,]\d+)?').firstMatch(s);
    return m == null ? null : double.tryParse(m.group(0)!.replaceAll(',', '.'));
  }
}

/// Two cascaded biquads: high-shelf "head" filter + RLB high-pass (BS.1770 stage 1 & 2).
class _KWeighting {
  _KWeighting(int fs) {
    // Stage 1: high shelf
    const f0 = 1681.974450955533;
    const g = 3.999843853973347;
    const q = 0.7071752369554196;
    final k = math.tan(math.pi * f0 / fs);
    final vh = math.pow(10.0, g / 20.0).toDouble();
    final vb = math.pow(vh, 0.4996667741545416).toDouble();
    final a0 = 1.0 + k / q + k * k;
    _b0a = (vh + vb * k / q + k * k) / a0;
    _b1a = 2.0 * (k * k - vh) / a0;
    _b2a = (vh - vb * k / q + k * k) / a0;
    _a1a = 2.0 * (k * k - 1.0) / a0;
    _a2a = (1.0 - k / q + k * k) / a0;

    // Stage 2: high pass
    const f1 = 38.13547087602444;
    const q1 = 0.5003270373238773;
    final k1 = math.tan(math.pi * f1 / fs);
    final a0b = 1.0 + k1 / q1 + k1 * k1;
    _a1b = 2.0 * (k1 * k1 - 1.0) / a0b;
    _a2b = (1.0 - k1 / q1 + k1 * k1) / a0b;
  }

  late final double _b0a, _b1a, _b2a, _a1a, _a2a;
  late final double _a1b, _a2b;
  double _x1a = 0, _x2a = 0, _y1a = 0, _y2a = 0;
  double _x1b = 0, _x2b = 0, _y1b = 0, _y2b = 0;

  double process(double x) {
    final ya = _b0a * x + _b1a * _x1a + _b2a * _x2a - _a1a * _y1a - _a2a * _y2a;
    _x2a = _x1a;
    _x1a = x;
    _y2a = _y1a;
    _y1a = ya;
    // RLB numerator is 1, -2, 1
    final yb = ya - 2.0 * _x1b + _x2b - _a1b * _y1b - _a2b * _y2b;
    _x2b = _x1b;
    _x1b = ya;
    _y2b = _y1b;
    _y1b = yb;
    return yb;
  }
}
