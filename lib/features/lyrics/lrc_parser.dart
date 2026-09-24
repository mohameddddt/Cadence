/// LRC ("LyRiCs") parsing for synchronised lyrics.
///
/// Supports `[mm:ss.xx]`, `[mm:ss.xxx]`, `[mm:ss]`, `[mm:ss:xx]`, `[hh:mm:ss.xx]`,
/// several timestamps in front of one line (repeated chorus), metadata tags
/// (`[ar:]`, `[ti:]`, `[offset:]`...) and ignores enhanced word timestamps (`<00:12.30>`).
class LrcLine {
  const LrcLine(this.time, this.text);

  final Duration time;
  final String text;

  @override
  String toString() => '[${time.inMilliseconds}ms] $text';
}

class LrcDocument {
  const LrcDocument(this.lines, {this.tags = const {}, this.offsetMs = 0});

  static const LrcDocument empty = LrcDocument([]);

  /// Sorted by time.
  final List<LrcLine> lines;
  final Map<String, String> tags;

  /// The file's own `[offset:]` in ms (positive = lyrics appear earlier).
  final int offsetMs;

  bool get isEmpty => lines.isEmpty;
  bool get isSynced => lines.isNotEmpty;

  /// Index of the line being sung at [position], or -1 before the first line.
  ///
  /// [userOffsetMs] is the per-track adjustment from the UI (positive = show lyrics
  /// later, i.e. compensates lyrics that appear too early).
  int indexAt(Duration position, {int userOffsetMs = 0}) {
    if (lines.isEmpty) return -1;
    final target = position.inMilliseconds - userOffsetMs + offsetMs;
    var lo = 0, hi = lines.length - 1, ans = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (lines[mid].time.inMilliseconds <= target) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }

  /// Start time of line [index] taking offsets into account (for tap-to-seek).
  Duration seekTimeFor(int index, {int userOffsetMs = 0}) {
    final ms = lines[index].time.inMilliseconds - offsetMs + userOffsetMs;
    return Duration(milliseconds: ms < 0 ? 0 : ms);
  }

  String get plainText => lines.map((l) => l.text).join('\n');

  // hh:mm:ss.xx is only recognised with a dot fraction; "a:b:c" otherwise means mm:ss:xx
  // (the older LRC flavour), which is by far the more common reading.
  static final RegExp _timestamp = RegExp(r'\[(?:(\d{1,2}):(?=\d{1,2}:\d{1,2}\.))?(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
  static final RegExp _tag = RegExp(r'^\[([A-Za-z#]+):(.*)\]\s*$');
  static final RegExp _wordTime = RegExp(r'<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>');

  static LrcDocument parse(String source) {
    final lines = <LrcLine>[];
    final tags = <String, String>{};
    var offset = 0;

    for (final raw in source.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n')) {
      var line = raw.trim();
      if (line.isEmpty) continue;
      // Byte-order mark on the first line.
      if (line.codeUnitAt(0) == 0xFEFF) line = line.substring(1).trim();

      final stamps = <Duration>[];
      var rest = line;
      while (true) {
        final m = _timestamp.matchAsPrefix(rest);
        if (m == null) break;
        stamps.add(_toDuration(m));
        rest = rest.substring(m.end);
      }

      if (stamps.isEmpty) {
        final t = _tag.firstMatch(line);
        if (t != null) {
          final key = t.group(1)!.toLowerCase();
          final value = t.group(2)!.trim();
          if (key == 'offset') {
            offset = int.tryParse(value.replaceFirst('+', '')) ?? 0;
          } else {
            tags[key] = value;
          }
        }
        // Anything else without a timestamp (headings, credits) is ignored.
        continue;
      }
      final text = rest.replaceAll(_wordTime, '').replaceAll(RegExp(r'\s{2,}'), ' ').trim();
      for (final s in stamps) {
        lines.add(LrcLine(s, text));
      }
    }
    // Dart's sort is not stable for lists > 32; add index as tiebreaker.
    final indexed = [for (var i = 0; i < lines.length; i++) (i, lines[i])];
    indexed.sort((a, b) {
      final c = a.$2.time.compareTo(b.$2.time);
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });
    return LrcDocument([for (final e in indexed) e.$2], tags: tags, offsetMs: offset);
  }

  static Duration _toDuration(Match m) {
    final hours = int.tryParse(m.group(1) ?? '') ?? 0;
    final minutes = int.parse(m.group(2)!);
    final seconds = int.parse(m.group(3)!);
    final frac = m.group(4);
    var ms = 0;
    if (frac != null) {
      // "5" -> 500 ms, "50" -> 500 ms, "500" -> 500 ms, "05" -> 50 ms
      ms = int.parse(frac.padRight(3, '0').substring(0, 3));
    }
    return Duration(hours: hours, minutes: minutes, seconds: seconds, milliseconds: ms);
  }

  /// True when [text] looks like LRC (at least one timestamped line).
  static bool looksSynced(String text) => _timestamp.hasMatch(text);
}
