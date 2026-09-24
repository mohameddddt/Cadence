import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/core/models/track.dart';
import 'package:musicplayer/features/downloader/source_detect.dart';

void main() {
  group('detectSource', () {
    test('youtu.be and watch URLs share one canonical form', () {
      final a = detectSource('https://youtu.be/dQw4w9WgXcQ?si=abc123');
      final b = detectSource('https://www.youtube.com/watch?v=dQw4w9WgXcQ&feature=share&list=RDdQw4w9WgXcQ');
      final c = detectSource('https://m.youtube.com/watch?v=dQw4w9WgXcQ&t=30s');
      for (final s in [a, b, c]) {
        expect(s.source, TrackSource.youtube);
        expect(s.canonicalUrl, 'https://www.youtube.com/watch?v=dQw4w9WgXcQ');
        expect(s.id, 'dQw4w9WgXcQ');
        expect(s.isPlaylist, isFalse);
      }
    });

    test('YouTube Music is its own source and keeps its host', () {
      final s = detectSource('https://music.youtube.com/watch?v=abc&si=zzz');
      expect(s.source, TrackSource.youtubeMusic);
      expect(s.canonicalUrl, 'https://music.youtube.com/watch?v=abc');
    });

    test('playlist links are recognised', () {
      final s = detectSource('https://www.youtube.com/playlist?list=PL123&si=x');
      expect(s.isPlaylist, isTrue);
      expect(s.canonicalUrl, 'https://www.youtube.com/playlist?list=PL123');
      expect(detectSource('https://music.youtube.com/playlist?list=OLAK5uy').isPlaylist, isTrue);
    });

    test('shorts and live URLs map to a watch URL', () {
      expect(detectSource('https://www.youtube.com/shorts/xyz').canonicalUrl, 'https://www.youtube.com/watch?v=xyz');
    });

    test('SoundCloud tracks, sets and profiles', () {
      final t = detectSource('https://soundcloud.com/artist/track-name?si=1&utm_source=clipboard');
      expect(t.source, TrackSource.soundcloud);
      expect(t.isPlaylist, isFalse);
      expect(t.canonicalUrl, 'https://soundcloud.com/artist/track-name');
      expect(detectSource('https://soundcloud.com/artist/sets/album').isPlaylist, isTrue);
      expect(detectSource('https://soundcloud.com/artist').isPlaylist, isTrue);
      expect(detectSource('https://soundcloud.com/artist/tracks').isPlaylist, isTrue);
    });

    test('SoundCloud private links keep their secret token', () {
      final s = detectSource('https://soundcloud.com/a/b/s-AbCdE?si=1');
      expect(s.canonicalUrl, 'https://soundcloud.com/a/b/s-AbCdE');
      final t = detectSource('https://soundcloud.com/a/b?secret_token=s-XYZ&si=1');
      expect(t.canonicalUrl, contains('secret_token=s-XYZ'));
      expect(t.canonicalUrl, isNot(contains('si=')));
    });

    test('Bandcamp albums are collections, tracks are not', () {
      expect(detectSource('https://artist.bandcamp.com/album/name').isPlaylist, isTrue);
      final t = detectSource('https://artist.bandcamp.com/track/song');
      expect(t.source, TrackSource.bandcamp);
      expect(t.isPlaylist, isFalse);
    });

    test('Internet Archive items normalise to /details/<id> and use the archive provider', () {
      final s = detectSource('https://archive.org/download/gd1977-05-08/gd77-05-08d1t01.mp3');
      expect(s.source, TrackSource.internetArchive);
      expect(s.canonicalUrl, 'https://archive.org/details/gd1977-05-08');
      expect(s.providerId, 'archive');
    });

    test('other supported hosts', () {
      expect(detectSource('https://www.mixcloud.com/x/y/').source, TrackSource.mixcloud);
      expect(detectSource('https://vimeo.com/123').source, TrackSource.vimeo);
      expect(detectSource('https://audius.co/artist/song').source, TrackSource.audius);
      expect(detectSource('https://www.twitch.tv/videos/1').source, TrackSource.twitch);
    });

    test('unknown sites are passed to yt-dlp, garbage is rejected', () {
      expect(detectSource('https://example.org/some/video').supportedByYtDlp, isTrue);
      expect(detectSource('not a url').supportedByYtDlp, isFalse);
    });

    test('unknown http:// pages keep their scheme (plain-http hosts exist)', () {
      expect(detectSource('http://10.0.0.5:8080/page?utm_source=x').canonicalUrl, 'http://10.0.0.5:8080/page');
      expect(detectSource('http://youtu.be/abc').canonicalUrl, startsWith('https://'));
    });

    test('links to audio files are downloaded directly, scheme and query untouched', () {
      final s = detectSource('http://10.0.2.2:8765/My_Song.OGG?token=abc');
      expect(s.directAudio, isTrue);
      expect(s.supportedByYtDlp, isFalse);
      expect(s.providerId, 'directfile');
      expect(s.canonicalUrl, 'http://10.0.2.2:8765/My_Song.OGG?token=abc');
      expect(detectSource('https://example.org/some/video').directAudio, isFalse);
      expect(detectSource('https://archive.org/download/x/y.mp3').directAudio, isFalse, reason: 'the archive provider owns these');
    });
  });

  group('extractUrl', () {
    test('finds the link inside share-sheet prose', () {
      expect(extractUrl('Check this out! https://youtu.be/abc?si=x  so good'), 'https://youtu.be/abc?si=x');
    });
    test('drops trailing punctuation', () {
      expect(extractUrl('see (https://soundcloud.com/a/b).'), 'https://soundcloud.com/a/b');
    });
    test('returns null without a link', () => expect(extractUrl('no link here'), isNull));
  });
}
