import 'musicbrainz_models.dart';

/// Chooses the "right" release when a recording appears on many (plan 4.2):
/// Official status -> Album type -> original (earliest) year -> the user's country ->
/// a digital or CD format.
class ReleasePicker {
  const ReleasePicker({this.preferredCountry = 'US'});

  final String preferredCountry;

  /// Returns the best release, or null for an empty list.
  MbRelease? pick(Iterable<MbRelease> releases) {
    MbRelease? best;
    List<int>? bestKey;
    var bestDate = '';
    for (final r in releases) {
      final key = _key(r);
      final date = r.date ?? '9999';
      if (best == null || _compare(key, bestKey!) < 0 || (_compare(key, bestKey) == 0 && date.compareTo(bestDate) < 0)) {
        best = r;
        bestKey = key;
        bestDate = date;
      }
    }
    return best;
  }

  /// Best-first ordering of all releases (used to show alternatives in the review UI).
  List<MbRelease> rank(Iterable<MbRelease> releases) {
    final list = releases.toList();
    final keys = {for (final r in list) r: _key(r)};
    list.sort((a, b) {
      final c = _compare(keys[a]!, keys[b]!);
      return c != 0 ? c : (a.date ?? '9999').compareTo(b.date ?? '9999');
    });
    return list;
  }

  int _compare(List<int> a, List<int> b) {
    for (var i = 0; i < a.length; i++) {
      final c = a[i].compareTo(b[i]);
      if (c != 0) return c;
    }
    return 0;
  }

  List<int> _key(MbRelease r) => [
        _statusRank(r.status),
        _typeRank(r),
        r.year ?? 9999,
        _countryRank(r.country),
        _formatRank(r.formats),
      ];

  int _statusRank(String? s) {
    switch (s?.toLowerCase()) {
      case 'official':
        return 0;
      case 'promotion':
        return 1;
      case null:
        return 2; // unknown
      case 'bootleg':
        return 3;
      case 'pseudo-release':
        return 4;
      default:
        return 2;
    }
  }

  int _typeRank(MbRelease r) {
    final primary = switch (r.primaryType?.toLowerCase()) {
      'album' => 0,
      'ep' => 1,
      'single' => 2,
      'broadcast' => 4,
      'other' => 4,
      _ => 3,
    };
    // Compilations, live albums, remixes... are a worse home for a studio recording.
    return primary + (r.secondaryTypes.isEmpty ? 0 : 10);
  }

  int _countryRank(String? c) {
    if (c == null) return 2;
    final u = c.toUpperCase();
    if (u == preferredCountry.toUpperCase()) return 0;
    if (u == 'XW') return 1; // worldwide
    return 2;
  }

  int _formatRank(List<String> formats) {
    if (formats.isEmpty) return 2;
    for (final f in formats) {
      final l = f.toLowerCase();
      if (l.contains('digital') || l == 'cd' || l.contains('cd')) return 0;
    }
    return 1;
  }
}
