import '../../core/library/album_grouping.dart';
import '../../core/library/library_repository.dart';
import '../../core/models/track.dart';
import '../../core/util/string_similarity.dart';

/// Finds the local track that corresponds to an (artist, title) pair from another service.
///
/// Titles differ in trivial ways between catalogues ("- Remastered 2011", "(feat. X)",
/// "The Beatles" vs "Beatles"), so both sides are reduced to a canonical key first.
class LibraryMatcher {
  LibraryMatcher(this.repo);

  final LibraryRepository repo;

  static final RegExp _suffixes = RegExp(
    r'\s*[\(\[\-–—]\s*(?:\d{4}\s*)?(?:remaster(?:ed)?|remix|mono|stereo|live|version|edit|single|album|explicit|clean|radio|deluxe|bonus|feat\.?|ft\.?|featuring|with)\b.*$',
    caseSensitive: false,
  );

  /// "Song - Remastered 2011" / "Song (feat. X)" -> "song".
  static String titleKey(String title) {
    var t = title;
    // remove up to two trailing decorations
    for (var i = 0; i < 2; i++) {
      final next = t.replaceFirst(_suffixes, '');
      if (next == t || next.trim().isEmpty) break;
      t = next;
    }
    return normalizeName(t);
  }

  /// "The Beatles" -> "beatles"; "Artist A, Artist B" -> "artist a" (first credited artist).
  static String artistKey(String artist) {
    var a = artist.split(RegExp(r'\s*(?:,|&|\bfeat\.?\b|\bft\.?\b|\bx\b| and )\s*', caseSensitive: false)).first;
    a = normalizeName(a);
    return a.startsWith('the ') ? a.substring(4) : a;
  }

  /// Best local track for [artist] + [title] (duration in ms improves accuracy), or null.
  Future<Track?> find({required String artist, required String title, int? durationMs, double minScore = 0.86}) async {
    final ak = artistKey(artist);
    final tk = titleKey(title);
    if (ak.isEmpty || tk.isEmpty) return null;
    // Narrow with the search index, then rank in Dart.
    final candidates = await repo.searchTracks('$tk ${ak.split(' ').first}', limit: 40);
    Track? best;
    var bestScore = 0.0;
    for (final t in candidates) {
      final ta = artistKey(t.artistName ?? '');
      final tt = titleKey(t.title);
      final artistSim = ta == ak ? 1.0 : StringSimilarity.ratio(ta, ak);
      final titleSim = tt == tk ? 1.0 : StringSimilarity.ratio(tt, tk);
      var score = titleSim * 0.65 + artistSim * 0.35;
      if (artistSim < 0.6 || titleSim < 0.75) continue;
      if (durationMs != null && durationMs > 0 && t.durationMs > 0) {
        final diff = (durationMs - t.durationMs).abs();
        if (diff > 15000) score -= 0.08;
      }
      if (score > bestScore) {
        bestScore = score;
        best = t;
      }
    }
    return bestScore >= minScore ? best : null;
  }
}
