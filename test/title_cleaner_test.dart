import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/features/metadata/title_cleaner.dart';

void main() {
  final c = TitleCleaner();

  ({String? artist, String title, List<String> featured}) run(String raw, {String? uploader}) {
    final r = c.clean(raw, uploader: uploader);
    return (artist: r.artist, title: r.title, featured: r.featured);
  }

  group('noise removal', () {
    final cases = <String, ({String? artist, String title})>{
      'Rick Astley - Never Gonna Give You Up (Official Video)': (artist: 'Rick Astley', title: 'Never Gonna Give You Up'),
      'Daft Punk - Get Lucky [Official Audio]': (artist: 'Daft Punk', title: 'Get Lucky'),
      'Queen – Bohemian Rhapsody (Official Video Remastered)': (artist: 'Queen', title: 'Bohemian Rhapsody'),
      'Adele - Hello (Lyrics)': (artist: 'Adele', title: 'Hello'),
      'Song Name (HD)': (artist: null, title: 'Song Name'),
      'Artist - Track (4K Remaster)': (artist: 'Artist', title: 'Track'),
      'Artist - Track | Visualizer': (artist: 'Artist', title: 'Track'),
      'Artist - Track - Official Music Video': (artist: 'Artist', title: 'Track'),
      'Artist - Track (Official Lyric Video) [HD]': (artist: 'Artist', title: 'Track'),
      'Artist - Track 🔥🔥 #newmusic #hiphop': (artist: 'Artist', title: 'Track'),
      'Artist - Track // Lyrics': (artist: 'Artist', title: 'Track'),
      'Artist - Track (Video Oficial)': (artist: 'Artist', title: 'Track'),
    };
    cases.forEach((input, want) {
      test(input, () {
        final r = run(input);
        expect(r.title, want.title);
        expect(r.artist, want.artist);
      });
    });

    test('keeps meaningful brackets such as versions', () {
      expect(run('Artist - Track (Radio Edit)').title, 'Track (Radio Edit)');
      expect(run('Artist - Track (Live at Wembley)').title, 'Track (Live at Wembley)');
      expect(run('Artist - Track (Acoustic)').title, 'Track (Acoustic)');
    });

    test('does not eat words that merely contain a noise word', () {
      expect(run('Artist - Videodrome (Official Video)').title, 'Videodrome');
      expect(run('Artist - Newborn').title, 'Newborn');
    });

    test('a title consisting only of noise falls back to the raw title', () {
      expect(run('(Official Video)').title, '(Official Video)');
    });
  });

  group('featured artists', () {
    test('bracketed', () {
      final r = run('Artist - Track (feat. Guest One & Guest Two)');
      expect(r.title, 'Track');
      expect(r.featured, ['Guest One', 'Guest Two']);
    });

    test('inline ft.', () {
      final r = run('Artist - Track ft. Guest [Official Video]');
      expect(r.title, 'Track');
      expect(r.featured, ['Guest']);
    });

    test('featuring in square brackets, comma separated', () {
      final r = run('Artist - Track [featuring A, B]');
      expect(r.featured, ['A', 'B']);
      expect(r.title, 'Track');
    });

    test('artistWithFeatured joins them for search queries', () {
      final r = c.clean('Artist - Track (ft. Guest)');
      expect(r.artistWithFeatured, 'Artist feat. Guest');
    });

    test('does not treat "soft." as ft.', () {
      expect(run('Artist - Soft. Touch').title, 'Soft. Touch');
    });
  });

  group('artist from uploader', () {
    test('- Topic channels supply the artist when the title has no prefix', () {
      final r = run('Bohemian Rhapsody', uploader: 'Queen - Topic');
      expect(r.artist, 'Queen');
      expect(r.title, 'Bohemian Rhapsody');
    });

    test('a prefix in the title wins over the uploader', () {
      final r = run('Queen - Bohemian Rhapsody', uploader: 'Some Random Channel');
      expect(r.artist, 'Queen');
    });

    test('ordinary uploader names are not trusted as the artist', () {
      final r = run('Bohemian Rhapsody', uploader: 'Some Random Channel');
      expect(r.artist, isNull);
    });

    test('cleanChannel strips Topic, VEVO and Official', () {
      expect(TitleCleaner.cleanChannel('Adele - Topic'), 'Adele');
      expect(TitleCleaner.cleanChannel('AdeleVEVO'), 'Adele');
      expect(TitleCleaner.cleanChannel('Adele Official'), 'Adele');
    });
  });

  test('only the first dash separates artist from title', () {
    final r = run('Artist - Track - Remix Name');
    expect(r.artist, 'Artist');
    expect(r.title, 'Track - Remix Name');
  });

  test('quotes around the title are removed', () {
    expect(run('Artist - "Track"').title, 'Track');
    expect(run('Artist - “Track”').title, 'Track');
  });

  group('user rules', () {
    test('custom regex rules are applied and invalid ones ignored', () {
      final custom = TitleCleaner.fromSettings('\\bNCS Release\\b\n([unclosed\n\n');
      expect(custom.clean('Artist - Track NCS Release').title, 'Track');
    });
  });
}
