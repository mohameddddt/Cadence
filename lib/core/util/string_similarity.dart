import 'dart:math' as math;

import '../library/album_grouping.dart' show normalizeName;

/// Similarity helpers for comparing titles/artists from different sources.
class StringSimilarity {
  const StringSimilarity._();

  /// 1.0 = identical after normalisation, 0.0 = nothing in common.
  static double ratio(String? a, String? b) {
    final x = normalizeName(a);
    final y = normalizeName(b);
    if (x.isEmpty && y.isEmpty) return 0;
    if (x == y) return 1;
    if (x.isEmpty || y.isEmpty) return 0;
    final lev = _levenshtein(x, y);
    final byChars = 1 - lev / math.max(x.length, y.length);
    return math.max(byChars, tokenOverlap(x, y) * 0.95);
  }

  /// Fraction of words shared (Dice coefficient on word sets).
  static double tokenOverlap(String a, String b) {
    final x = a.split(' ').where((e) => e.isNotEmpty).toSet();
    final y = b.split(' ').where((e) => e.isNotEmpty).toSet();
    if (x.isEmpty || y.isEmpty) return 0;
    final common = x.intersection(y).length;
    return 2 * common / (x.length + y.length);
  }

  static int _levenshtein(String a, String b) {
    var prev = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      final cur = List<int>.filled(b.length + 1, 0)..[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        cur[j] = math.min(math.min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost);
      }
      prev = cur;
    }
    return prev[b.length];
  }
}
