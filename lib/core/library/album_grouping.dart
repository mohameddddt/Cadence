/// Pure helpers for deciding which tracks belong to the same album.
///
/// The plan requires grouping by (albumArtist, album) so compilations don't split into
/// one album per artist, and MusicBrainz release ids winning when they exist.
library;

final RegExp _nonWord = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

/// Case/punctuation-insensitive form used for keys and comparisons.
String normalizeName(String? s) {
  if (s == null) return '';
  return s.toLowerCase().replaceAll(_nonWord, ' ').trim();
}

const Set<String> _variousArtists = {'various artists', 'various', 'va', 'v a', 'varios artistas'};

bool isVariousArtists(String? name) => _variousArtists.contains(normalizeName(name));

/// Returns null when the track has no album at all.
///
/// Priority: MusicBrainz release id > album-artist tag + album > folder + album
/// (files that carry no album-artist but sit in one folder are one album, even when
/// the per-track artists differ - i.e. a compilation).
String? albumGroupKey({
  String? album,
  String? albumArtist,
  String? folder,
  String? mbReleaseId,
}) {
  final a = normalizeName(album);
  if (a.isEmpty) return null;
  if (mbReleaseId != null && mbReleaseId.isNotEmpty) return 'mb:${mbReleaseId.toLowerCase()}';
  final aa = normalizeName(albumArtist);
  if (aa.isNotEmpty) return 'aa:$aa|$a';
  return 'f:${folder ?? ''}|$a';
}

/// Chooses the album-level artist name for a set of track artists.
///
/// [albumArtistTag] wins when present; otherwise a single distinct artist is used and
/// several distinct artists collapse to "Various Artists".
String? resolveAlbumArtist({String? albumArtistTag, required Iterable<String?> trackArtists}) {
  if (albumArtistTag != null && albumArtistTag.trim().isNotEmpty) return albumArtistTag.trim();
  final distinct = <String, String>{};
  for (final a in trackArtists) {
    if (a == null || a.trim().isEmpty) continue;
    distinct.putIfAbsent(normalizeName(a), () => a.trim());
  }
  if (distinct.isEmpty) return null;
  if (distinct.length == 1) return distinct.values.first;
  return 'Various Artists';
}
