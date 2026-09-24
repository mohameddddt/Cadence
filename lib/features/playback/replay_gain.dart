import 'dart:math' as math;

import '../../core/settings/settings_store.dart';

/// How a ReplayGain value is applied on Android.
///
/// ExoPlayer's volume can only attenuate (0..1). Negative gains are therefore applied
/// as volume; positive gains (quiet tracks) use the LoudnessEnhancer effect instead.
class ReplayGainResult {
  const ReplayGainResult({required this.volume, required this.boostDb});

  final double volume;
  final double boostDb;

  static const ReplayGainResult neutral = ReplayGainResult(volume: 1, boostDb: 0);

  @override
  String toString() => 'ReplayGainResult(volume: ${volume.toStringAsFixed(3)}, boostDb: $boostDb)';
}

class ReplayGain {
  const ReplayGain._();

  /// Maximum amplification we allow through LoudnessEnhancer, to avoid pumping clipping.
  static const double maxBoostDb = 12;

  static ReplayGainResult compute({
    required ReplayGainMode mode,
    double? trackGain,
    double? albumGain,
    double preampDb = 0,
    double untaggedPreampDb = 0,
  }) {
    if (mode == ReplayGainMode.off) return ReplayGainResult.neutral;
    // Album mode falls back to track gain and vice versa, like most players.
    final gain = mode == ReplayGainMode.album ? (albumGain ?? trackGain) : (trackGain ?? albumGain);
    final db = (gain ?? untaggedPreampDb) + preampDb;
    if (gain == null && preampDb == 0 && untaggedPreampDb == 0) return ReplayGainResult.neutral;
    if (db <= 0) {
      return ReplayGainResult(volume: math.pow(10, db / 20).toDouble().clamp(0.0, 1.0), boostDb: 0);
    }
    return ReplayGainResult(volume: 1, boostDb: db.clamp(0, maxBoostDb).toDouble());
  }
}
