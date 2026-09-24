/// Turns video-style titles into something MusicBrainz can match (plan 4.3).
///
/// "Artist - Song (Official Video) [4K] ft. Someone #music" ->
///   artist: Artist, title: Song, featured: [Someone]
class CleanedTitle {
  const CleanedTitle({required this.title, this.artist, this.featured = const []});

  final String title;
  final String? artist;
  final List<String> featured;

  /// Artist string including featured guests, for search queries.
  String? get artistWithFeatured =>
      artist == null ? null : (featured.isEmpty ? artist : '$artist feat. ${featured.join(', ')}');

  @override
  String toString() => 'CleanedTitle(artist: $artist, title: $title, featured: $featured)';
}

class TitleCleaner {
  /// [extraRules] are user supplied regular expressions (one per entry, case-insensitive)
  /// whose matches are deleted from titles. Invalid patterns are ignored.
  TitleCleaner({Iterable<String> extraRules = const []})
      : _extra = [
          for (final r in extraRules)
            if (r.trim().isNotEmpty) ..._tryCompile(r.trim()),
        ];

  final List<RegExp> _extra;

  /// Same, from the multi-line settings string.
  factory TitleCleaner.fromSettings(String rules) => TitleCleaner(extraRules: rules.split('\n'));

  static Iterable<RegExp> _tryCompile(String source) {
    try {
      return [RegExp(source, caseSensitive: false, unicode: true)];
    } on FormatException {
      return const [];
    }
  }

  static const String _noiseWords = r'official|music\s*video|lyric(?:s)?(?:\s*video)?|with\s*lyrics|video|audio|'
      r'visuali[sz]er|hd|hq|4k|8k|uhd|1080p|720p|480p|remaster(?:ed)?(?:\s*\d{4})?|'
      r'(?:\d{4}\s*)?remaster(?:ed)?(?:\s*version)?|full\s*(?:song|album|version)|audio\s*only|explicit|'
      r'clean|free\s*download|out\s*now|new|mv|m/v|vídeo\s*oficial|video\s*oficial|videoclip|clip\s*officiel|'
      r'letra|lyrics?\s*on\s*screen|topic|premiere|videoclipe|oficial|subtitulado|sub\s*español|hd\s*audio|'
      r'high\s*quality|high\s*res(?:olution)?';

  // (Official Video), [Lyrics], {HD}...  Only removed when *every* word in it is noise.
  static final RegExp _bracket = RegExp(
    r'[\(\[\{]\s*((?:(?:' + _noiseWords + r')[\s,&/+\-–]*)+)\s*[\)\]\}]',
    caseSensitive: false,
    unicode: true,
  );

  // "... | Visualizer", "- Official Video", "// Lyrics" at the very end
  static final RegExp _trailingNoise = RegExp(
    r'\s*(?:[|/]{1,2}|[-–—]\s+)\s*(?:(?:' + _noiseWords + r')[\s,&/+\-–]*)+$',
    caseSensitive: false,
    unicode: true,
  );

  static final RegExp _hashtag = RegExp(r'#[\p{L}\p{N}_]+', unicode: true);

  static final RegExp _emoji = RegExp(
    '[\u{1F000}-\u{1FAFF}\u{2190}-\u{21FF}\u{2300}-\u{23FF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{FE0F}\u{200D}\u{20E3}]',
    unicode: true,
  );

  // (feat. X), [ft X], "ft. X" up to the next bracket / dash / end.
  static final RegExp _featBracket = RegExp(
    r'[\(\[]\s*(?:feat(?:uring)?|ft)\b\.?\s*([^\)\]]+?)\s*[\)\]]',
    caseSensitive: false,
    unicode: true,
  );
  static final RegExp _featInline = RegExp(
    r'\s+(?:feat(?:uring)?|ft)\b\.?\s+(.+?)(?=\s+[-–—|]\s|\s*[\(\[]|$)',
    caseSensitive: false,
    unicode: true,
  );

  static final RegExp _dashSplit = RegExp(r'\s+[-–—]\s+');
  static final RegExp _spaces = RegExp(r'\s{2,}');

  /// Cleans [raw]. [uploader] (the channel name) is used when the title itself carries
  /// no "Artist - " prefix, e.g. auto-generated "Artist - Topic" channels.
  CleanedTitle clean(String raw, {String? uploader}) {
    var s = raw;
    s = s.replaceAll(_emoji, ' ').replaceAll(_hashtag, ' ');

    for (final r in _extra) {
      s = s.replaceAll(r, ' ');
    }

    // Featured artists first so their brackets don't confuse the noise pass.
    final featured = <String>[];
    s = s.replaceAllMapped(_featBracket, (m) {
      featured.addAll(_splitNames(m.group(1)!));
      return ' ';
    });
    s = s.replaceAllMapped(_featInline, (m) {
      featured.addAll(_splitNames(m.group(1)!));
      return ' ';
    });

    // Repeat: "(Official Video) [HD]" style stacks.
    String prev;
    do {
      prev = s;
      s = s.replaceAll(_bracket, ' ');
      s = s.replaceAll(_trailingNoise, '');
    } while (s != prev);

    s = s.replaceAll(_spaces, ' ').trim();
    // Dangling separators left by removed parts.
    s = s.replaceAll(RegExp(r'^[\s\-–—|/:]+|[\s\-–—|/:]+$'), '').trim();

    String? artist;
    var title = s;
    final parts = s.split(_dashSplit);
    final topicArtist = uploader != null && _topic.hasMatch(uploader) ? cleanChannel(uploader) : null;
    if (parts.length >= 2 && parts.first.trim().isNotEmpty && parts.sublist(1).join(' - ').trim().isNotEmpty) {
      artist = parts.first.trim();
      title = parts.sublist(1).join(' - ').trim();
    } else if (topicArtist != null) {
      artist = topicArtist;
    } else if (uploader != null && uploader.trim().isNotEmpty) {
      // Plain uploader name is only a hint; leave null so identification decides.
      artist = null;
    }

    title = _unquote(title);
    artist = artist == null ? null : _unquote(artist);
    return CleanedTitle(
      title: title.isEmpty ? raw.trim() : title,
      artist: (artist == null || artist.isEmpty) ? null : artist,
      featured: [
        for (final f in featured)
          if (f.isNotEmpty) f,
      ],
    );
  }

  static final RegExp _topic = RegExp(r'\s*[-–]\s*topic\s*$', caseSensitive: false);
  static final RegExp _vevo = RegExp(r'\s*vevo\s*$', caseSensitive: false);
  static final RegExp _officialSuffix = RegExp(r'\s+(official|music)(\s+(channel|page))?\s*$', caseSensitive: false);

  /// "Adele - Topic" -> "Adele", "AdeleVEVO" -> "Adele".
  static String cleanChannel(String channel) {
    var c = channel.trim();
    c = c.replaceAll(_topic, '');
    c = c.replaceAll(_vevo, '');
    c = c.replaceAll(_officialSuffix, '');
    return c.trim();
  }

  static List<String> _splitNames(String s) => s
      .split(RegExp(r'\s*(?:,|&|\band\b|\bx\b|\+)\s*', caseSensitive: false))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  static String _unquote(String s) {
    var t = s.trim();
    if (t.length > 1) {
      const pairs = {'"': '"', '“': '”', '‘': '’', "'": "'", '«': '»'};
      final close = pairs[t[0]];
      if (close != null && t.endsWith(close)) t = t.substring(1, t.length - 1).trim();
    }
    return t;
  }
}
