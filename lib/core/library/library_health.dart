/// Pure helpers behind the dashboard's "needs attention" lists.
library;

import '../models/library_models.dart';
import 'album_grouping.dart';

const Map<String, String> _accents = {
  'a': 'àáâãäåāăą',
  'c': 'çćč',
  'd': 'ďđ',
  'e': 'èéêëēėęě',
  'g': 'ğ',
  'i': 'ìíîïīį',
  'l': 'ł',
  'n': 'ñńň',
  'o': 'òóôõöøōő',
  'r': 'ř',
  's': 'śšş',
  't': 'ť',
  'u': 'ùúûüūůűų',
  'y': 'ýÿ',
  'z': 'źżž',
};
final Map<String, String> _fold = {
  for (final e in _accents.entries)
    for (final r in e.value.runes) String.fromCharCode(r): e.key,
};

/// "Beyoncé" -> "beyonce". Only the Latin letters music libraries actually contain.
String foldDiacritics(String s) {
  final b = StringBuffer();
  for (final r in s.toLowerCase().runes) {
    final c = String.fromCharCode(r);
    b.write(_fold[c] ?? c);
  }
  return b.toString();
}

/// Identity of an artist for duplicate detection: case, accents, punctuation, spacing and a
/// leading article are ignored ("The Beatles" = "Beatles" = "the  beatles", "AC/DC" = "AC DC").
String artistKey(String name) {
  var n = normalizeName(foldDiacritics(name));
  n = n.replaceFirst(RegExp(r'^(the|a|an) '), '');
  return n.replaceAll(' ', '');
}

/// Identity of an album for duplicate detection: same title by the same artist.
String albumKey(Album a) => '${normalizeName(foldDiacritics(a.title))}|${artistKey(a.artistName ?? '')}';

/// Groups of two or more entries sharing a key, largest key order preserved as encountered.
Map<String, List<T>> _groupDuplicates<T>(Iterable<T> items, String Function(T) key) {
  final groups = <String, List<T>>{};
  for (final i in items) {
    final k = key(i);
    if (k.isEmpty || k == '|') continue;
    groups.putIfAbsent(k, () => []).add(i);
  }
  groups.removeWhere((_, v) => v.length < 2);
  return groups;
}

/// Ids of artists that look like duplicates of another artist.
Set<int> duplicateArtistIds(Iterable<Artist> artists) => {
  for (final g in _groupDuplicates(artists, (a) => artistKey(a.name)).values)
    for (final a in g) a.id,
};

/// Ids of albums that look like duplicates of another album.
Set<int> duplicateAlbumIds(Iterable<Album> albums) => {
  for (final g in _groupDuplicates(albums, albumKey).values)
    for (final a in g) a.id,
};

/// Sorts so that duplicates sit next to each other (used when the duplicates filter is on).
int compareArtistsByKey(Artist a, Artist b) => artistKey(a.name).compareTo(artistKey(b.name));

int compareAlbumsByKey(Album a, Album b) => albumKey(a).compareTo(albumKey(b));

/// "3 d 4 h", "12 h 5 min", "48 min".
String formatTotalDuration(int ms) {
  final minutes = ms ~/ 60000;
  final h = minutes ~/ 60;
  final d = h ~/ 24;
  if (d > 0) return '$d d ${h % 24} h';
  if (h > 0) return '$h h ${minutes % 60} min';
  return '$minutes min';
}
