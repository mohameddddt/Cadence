import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/core/util/filename_template.dart';

void main() {
  const t = FilenameTemplate('{artist}/{album}/{track:02} - {title}');

  test('renders a complete tag set', () {
    expect(
      t.render({'artist': 'Queen', 'album': 'A Night at the Opera', 'track': 11, 'title': 'Bohemian Rhapsody'}),
      'Queen/A Night at the Opera/11 - Bohemian Rhapsody',
    );
  });

  test('zero-pads and leaves larger numbers alone', () {
    expect(t.render({'artist': 'A', 'album': 'B', 'track': 3, 'title': 'C'}), 'A/B/03 - C');
    expect(t.render({'artist': 'A', 'album': 'B', 'track': 103, 'title': 'C'}), 'A/B/103 - C');
  });

  test('missing track number does not leave a dangling " - "', () {
    expect(t.render({'artist': 'A', 'album': 'B', 'title': 'C'}), 'A/B/C');
    expect(t.render({'artist': 'A', 'album': 'B', 'track': 0, 'title': 'C'}), 'A/B/C');
  });

  test('missing artist/album fall back to Unknown, or to the inline fallback', () {
    expect(t.render({'title': 'C'}), 'Unknown Artist/Unknown Album/C');
    const singles = FilenameTemplate(FilenameTemplate.defaultTemplate);
    expect(singles.render({'artist': 'A', 'title': 'C'}), 'A/Singles/C');
  });

  test('path separators and illegal characters inside values are replaced', () {
    expect(t.render({'artist': 'AC/DC', 'album': 'Who Made Who?', 'track': 1, 'title': 'For Those About "Rock"'}),
        'AC_DC/Who Made Who/01 - For Those About _Rock');
  });

  test('trailing dots and spaces are trimmed (invalid on FAT/NTFS)', () {
    expect(t.render({'artist': 'Mr. ', 'album': 'Album...', 'track': 1, 'title': 'T.'}), 'Mr/Album/01 - T');
  });

  test('reserved device names are neutralised', () {
    expect(FilenameTemplate.sanitizeSegment('CON'), '_CON');
    expect(FilenameTemplate.sanitizeSegment('lpt1'), '_lpt1');
    expect(FilenameTemplate.sanitizeSegment('Console'), 'Console');
  });

  test('very long segments are truncated', () {
    final long = 'x' * 300;
    expect(t.render({'artist': long, 'album': 'B', 'track': 1, 'title': 'C'}).split('/').first.length, 120);
  });

  test('unicode is preserved', () {
    expect(t.render({'artist': 'Björk', 'album': 'Homogénic', 'track': 2, 'title': 'Jóga'}), 'Björk/Homogénic/02 - Jóga');
  });

  test('other placeholders: disc, year, albumartist, and unknown ones vanish', () {
    const f = FilenameTemplate('{albumartist} ({year})/{disc}-{track:02} {title}{bogus}');
    expect(f.render({'albumartist': 'X', 'year': 1999, 'disc': 2, 'track': 4, 'title': 'T'}), 'X (1999)/2-04 T');
  });

  test('nothing usable falls back to the title', () {
    const f = FilenameTemplate('{track}');
    expect(f.render({'title': 'Only Title'}), 'Only Title');
  });
}
