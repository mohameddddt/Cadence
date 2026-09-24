/// Renders `{artist}/{album}/{track:02} - {title}` style templates into safe relative
/// paths (no extension). Used to organise downloads after identification.
///
/// Placeholders: artist, albumartist, album, title, track, disc, year, genre, source.
/// Modifiers: `{track:02}` zero-pads numbers, `{album|Singles}` supplies a fallback
/// used when the value is missing.
class FilenameTemplate {
  const FilenameTemplate(this.template);

  final String template;

  static const String defaultTemplate = '{artist}/{album|Singles}/{track:02} - {title}';

  static const Map<String, String> _fallbacks = {
    'artist': 'Unknown Artist',
    'albumartist': 'Unknown Artist',
    'album': 'Unknown Album',
    'title': 'Untitled',
  };

  static final RegExp _placeholder = RegExp(r'\{([a-zA-Z]+)(?::(\d+))?(?:\|([^}]*))?\}');
  static final RegExp _illegal = RegExp(r'[\\/:*?"<>|\u0000-\u001F]');

  /// Returns a relative path such as `Artist/Album/03 - Title` (forward slashes).
  String render(Map<String, Object?> values, {int maxSegmentLength = 120}) {
    final segments = <String>[];
    for (final rawSegment in template.split('/')) {
      final filled = rawSegment.replaceAllMapped(_placeholder, (m) {
        final key = m.group(1)!.toLowerCase();
        final pad = int.tryParse(m.group(2) ?? '');
        var value = values[key];
        String text;
        if (value == null || (value is String && value.trim().isEmpty) || (value is num && value <= 0 && key != 'year')) {
          text = m.group(3) ?? (key == 'track' || key == 'disc' || key == 'year' ? '' : (_fallbacks[key] ?? ''));
        } else if (value is num && pad != null) {
          text = value.toInt().toString().padLeft(pad, '0');
        } else {
          text = value.toString();
        }
        return text;
      });
      final cleaned = sanitizeSegment(filled, maxSegmentLength);
      if (cleaned.isNotEmpty) segments.add(cleaned);
    }
    if (segments.isEmpty) return sanitizeSegment(values['title']?.toString() ?? 'Untitled', maxSegmentLength);
    return segments.join('/');
  }

  /// Makes one path component safe on Android/FAT/NTFS: strips illegal characters,
  /// dangling separators left by empty placeholders, trailing dots/spaces, and limits length.
  static String sanitizeSegment(String s, [int maxLength = 120]) {
    var t = s.replaceAll(_illegal, '_').replaceAll(RegExp(r'\s+'), ' ').trim();
    // "  - Title" (missing track number) -> "Title"; "Artist - " -> "Artist"
    t = t.replaceAll(RegExp(r'^[\s\-_.]+'), '').replaceAll(RegExp(r'[\s\-_.]+$'), '');
    if (t.length > maxLength) t = t.substring(0, maxLength).trim();
    // Reserved Windows device names matter for SD cards / exported libraries.
    if (RegExp(r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])$', caseSensitive: false).hasMatch(t)) t = '_$t';
    return t;
  }
}
