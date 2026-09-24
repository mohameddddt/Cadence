import 'dart:math' as math;
import 'dart:typed_data';

/// Band-limited sample-rate conversion (windowed-sinc, Blackman window).
///
/// Chromaprint needs 11025 Hz mono; decoding at the native rate and filtering here
/// avoids the aliasing a naive decimation would fold into the chroma bands.
class Resampler {
  const Resampler._();

  /// Resamples mono [input] from [inRate] to [outRate].
  ///
  /// [cutoff] is the low-pass edge as a fraction of the *output* Nyquist frequency
  /// (Chromaprint's own resampler uses 0.8). [zeroCrossings] is the kernel half-width
  /// measured in sinc zero crossings.
  static Float64List resample(
    Float64List input,
    int inRate,
    int outRate, {
    double cutoff = 0.8,
    int zeroCrossings = 6,
  }) {
    if (inRate == outRate) return Float64List.fromList(input);
    final ratio = inRate / outRate; // input samples per output sample
    final outLength = ((input.length - 1) / ratio).floor() + 1;
    if (input.isEmpty || outLength <= 0) return Float64List(0);
    final out = Float64List(outLength);

    // Cut-off relative to the input rate (cycles per input sample).
    final downsampling = outRate < inRate;
    final fc = downsampling ? cutoff * 0.5 / ratio : 0.5 * cutoff;
    final halfWidth = (zeroCrossings / (2 * fc)).ceil();

    // Pre-computed kernel over a fine grid of fractional offsets would be faster, but
    // direct evaluation keeps the code obvious and is fast enough for 2 minutes of audio.
    final twoPi = 2 * math.pi;
    for (var n = 0; n < outLength; n++) {
      final pos = n * ratio;
      final centre = pos.floor();
      final from = math.max(0, centre - halfWidth + 1);
      final to = math.min(input.length - 1, centre + halfWidth);
      var acc = 0.0;
      var norm = 0.0;
      for (var k = from; k <= to; k++) {
        final d = k - pos;
        final x = twoPi * fc * d;
        final sinc = d == 0 ? 1.0 : math.sin(x) / x;
        final t = (d / halfWidth + 1) / 2; // 0..1 across the window
        final w = 0.42 - 0.5 * math.cos(twoPi * t) + 0.08 * math.cos(2 * twoPi * t);
        final h = sinc * w;
        acc += input[k] * h;
        norm += h;
      }
      // Normalising by the kernel sum keeps unity DC gain at the edges of the signal.
      out[n] = norm.abs() < 1e-12 ? 0 : acc / norm;
    }
    return out;
  }
}
