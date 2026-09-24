import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/core/models/track.dart';
import 'package:musicplayer/core/settings/settings_store.dart';
import 'package:musicplayer/features/downloader/download_models.dart';
import 'package:musicplayer/features/downloader/ytdlp_args.dart';

import 'helpers/fakes.dart';

void main() {
  group('YtDlpArgs.download', () {
    List<String> build(DownloadOptions o, {TrackSource? source, String url = 'https://youtu.be/x'}) =>
        YtDlpArgs.download(url, workDir: '/tmp/job1', options: o, source: source);

    bool hasPair(List<String> a, String flag, String value) {
      final i = a.indexOf(flag);
      return i >= 0 && i + 1 < a.length && a[i + 1] == value;
    }

    test('always: best audio, extract, metadata, info json, one item, machine-readable progress', () {
      final a = build(const DownloadOptions());
      expect(hasPair(a, '-f', 'bestaudio/best'), isTrue);
      expect(a, containsAll(['-x', '--embed-metadata', '--write-info-json', '--no-playlist', '--newline', '--progress']));
      expect(hasPair(a, '-P', '/tmp/job1'), isTrue);
      expect(hasPair(a, '-o', '%(id)s.%(ext)s'), isTrue);
      expect(a.last, 'https://youtu.be/x', reason: 'the URL goes last');
    });

    test('original keeps the native stream: no --audio-format', () {
      final a = build(const DownloadOptions(format: AudioFormatChoice.original));
      expect(a, isNot(contains('--audio-format')));
      expect(a, isNot(contains('--audio-quality')));
    });

    test('conversion formats set --audio-format and best quality', () {
      for (final f in [AudioFormatChoice.mp3, AudioFormatChoice.m4a, AudioFormatChoice.opus]) {
        final a = build(DownloadOptions(format: f, quality: 0));
        expect(hasPair(a, '--audio-format', f.name), isTrue);
        expect(hasPair(a, '--audio-quality', '0'), isTrue);
      }
      final flac = build(const DownloadOptions(format: AudioFormatChoice.flac));
      expect(hasPair(flac, '--audio-format', 'flac'), isTrue);
      expect(flac, isNot(contains('--audio-quality')), reason: 'lossless has no quality knob');
    });

    test('thumbnails are handled by the app by default; yt-dlp embedding is opt-in and converts to jpg', () {
      expect(build(const DownloadOptions()), isNot(contains('--embed-thumbnail')));
      final a = build(const DownloadOptions(embedThumbnail: true));
      expect(a, contains('--embed-thumbnail'));
      expect(hasPair(a, '--convert-thumbnails', 'jpg'), isTrue);
    });

    test('"Artist - Title" parsing is on by default', () {
      expect(hasPair(build(const DownloadOptions()), '--parse-metadata', 'title:%(artist)s - %(title)s'), isTrue);
      expect(build(const DownloadOptions(parseTitle: false)), isNot(contains('--parse-metadata')));
    });

    test('SponsorBlock only for YouTube sources and only when enabled', () {
      expect(hasPair(build(const DownloadOptions(), source: TrackSource.youtube), '--sponsorblock-remove', 'music_offtopic'), isTrue);
      expect(hasPair(build(const DownloadOptions(), source: TrackSource.youtubeMusic), '--sponsorblock-remove', 'music_offtopic'), isTrue);
      expect(build(const DownloadOptions(), source: TrackSource.soundcloud), isNot(contains('--sponsorblock-remove')));
      expect(build(const DownloadOptions(sponsorBlock: false), source: TrackSource.youtube), isNot(contains('--sponsorblock-remove')));
    });

    test('cookies, rate limit, aria2 and user extras are passed through, before the URL', () {
      final a = build(const DownloadOptions(cookiesFile: '/c/cookies.txt', limitRate: '2M', useAria2: true, extraArgs: ['--geo-bypass']));
      expect(hasPair(a, '--cookies', '/c/cookies.txt'), isTrue);
      expect(hasPair(a, '--limit-rate', '2M'), isTrue);
      expect(hasPair(a, '--downloader', 'aria2c'), isTrue);
      expect(a.indexOf('--geo-bypass'), lessThan(a.length - 1));
    });

    test('retries are configured', () {
      final a = build(const DownloadOptions());
      expect(hasPair(a, '--retries', '5'), isTrue);
      expect(hasPair(a, '--fragment-retries', '5'), isTrue);
    });

    test('options come from settings', () async {
      final s = await testSettings({'dl.format': 'mp3', 'dl.quality': 2, 'dl.sponsorblock': false, 'dl.extraArgs': '--foo\n\n --bar '});
      final o = DownloadOptions.fromSettings(s);
      expect(o.format, AudioFormatChoice.mp3);
      expect(o.quality, 2);
      expect(o.sponsorBlock, isFalse);
      expect(o.extraArgs, ['--foo', '--bar']);
      final back = DownloadOptions.fromJson(o.toJson());
      expect(back.format, o.format);
      expect(back.extraArgs, o.extraArgs);
    });
  });

  group('other command lines', () {
    test('info / playlist / search / stream', () {
      expect(YtDlpArgs.info('u'), containsAll(['-J', '--no-playlist', '--skip-download']));
      expect(YtDlpArgs.flatPlaylist('u'), containsAll(['-J', '--flat-playlist']));
      expect(YtDlpArgs.search('ytsearch', 'daft punk', 10).last, 'ytsearch10:daft punk');
      expect(YtDlpArgs.streamUrl('u'), containsAll(['-g', '-f', 'bestaudio/best']));
      expect(YtDlpArgs.searchPrefix(TrackSource.soundcloud), 'scsearch');
      expect(YtDlpArgs.searchPrefix(TrackSource.bandcamp), isNull);
    });

    test('progress parsing', () {
      expect(YtDlpArgs.parsePercent('[download]  42.3% of ~ 4.20MiB at  1.2MiB/s ETA 00:03'), 42.3);
      expect(YtDlpArgs.parsePercent('[download] 100% of 3.50MiB in 00:02'), 100);
      expect(YtDlpArgs.parsePercent('[info] Something'), isNull);
      expect(YtDlpArgs.stageOf('[ExtractAudio] Destination: x.m4a'), 'Converting audio');
      expect(YtDlpArgs.stageOf('[EmbedThumbnail] ffmpeg: Adding thumbnail'), 'Embedding metadata');
      expect(YtDlpArgs.stageOf('nothing'), isNull);
    });
  });

  group('MediaInfo.fromJson', () {
    test('a YouTube Music track carries artist/album/track', () {
      final i = MediaInfo.fromJson({
        'id': 'abc',
        'title': 'Bohemian Rhapsody (Remastered 2011)',
        'track': 'Bohemian Rhapsody',
        'artists': ['Queen'],
        'album': 'A Night At The Opera',
        'release_year': 1975,
        'duration': 354.3,
        'uploader': 'Queen Official',
        'webpage_url': 'https://music.youtube.com/watch?v=abc',
        'extractor_key': 'Youtube',
        'thumbnails': [
          {'url': 'small'},
          {'url': 'https://big.jpg'}
        ],
      });
      expect(i.artist, 'Queen');
      expect(i.album, 'A Night At The Opera');
      expect(i.track, 'Bohemian Rhapsody');
      expect(i.releaseYear, 1975);
      expect(i.durationSec, 354);
      expect(i.thumbnail, 'https://big.jpg');
      expect(i.source, TrackSource.youtubeMusic);
      expect(i.isPlaylist, isFalse);
    });

    test('plain video: year from upload date, uploader as artist hint', () {
      final i = MediaInfo.fromJson({'id': 'x', 'title': 'Song', 'uploader': 'Some Channel', 'upload_date': '20190516', 'webpage_url': 'https://youtu.be/x'});
      expect(i.releaseYear, 2019);
      expect(i.artist, isNull);
      expect(i.bestArtist, 'Some Channel');
    });

    test('playlists expose their entries', () {
      final i = MediaInfo.fromJson({
        '_type': 'playlist',
        'title': 'Mix',
        'webpage_url': 'https://youtube.com/playlist?list=1',
        'entries': [
          {'id': 'a', 'title': 'One', 'url': 'https://youtube.com/watch?v=a', 'playlist_index': 1},
          {'id': 'b', 'title': 'Two', 'url': 'https://youtube.com/watch?v=b', 'playlist_index': 2, 'duration': 100},
        ],
      });
      expect(i.isPlaylist, isTrue);
      expect(i.entries.map((e) => e.title), ['One', 'Two']);
      expect(i.entries.first.url, 'https://youtube.com/watch?v=a');
      expect(i.entries.last.trackNumber, 2);
    });
  });

  group('DownloadError.classify', () {
    final cases = <String, DownloadErrorKind>{
      'ERROR: [youtube] abc: Sign in to confirm you’re not a bot': DownloadErrorKind.signInRequired,
      'ERROR: Sign in to confirm your age. This video may be inappropriate': DownloadErrorKind.ageRestricted,
      'ERROR: Video unavailable': DownloadErrorKind.unavailable,
      'ERROR: This video is private': DownloadErrorKind.unavailable,
      'ERROR: The uploader has not made this video available in your country': DownloadErrorKind.geoBlocked,
      'ERROR: unable to download video data: HTTP Error 403: Forbidden': DownloadErrorKind.forbidden,
      'HTTP Error 429: Too Many Requests': DownloadErrorKind.rateLimited,
      'ERROR: Unable to extract initial data; please report this issue on GitHub': DownloadErrorKind.needsUpdate,
      'ERROR: Signature extraction failed': DownloadErrorKind.needsUpdate,
      'ERROR: ffmpeg not found. Please install': DownloadErrorKind.ffmpeg,
      'OSError: [Errno 28] No space left on device': DownloadErrorKind.noSpace,
      'ERROR: Unable to download webpage: <urlopen error [Errno -2] Name or service not known>': DownloadErrorKind.network,
      'The read operation timed out': DownloadErrorKind.network,
      'SocketException: Connection reset by peer - unknown': DownloadErrorKind.network,
      'HttpException: Connection closed before full header was received - unknown': DownloadErrorKind.network,
      'SocketException: Failed host lookup: cdn.example.org': DownloadErrorKind.network,
    };
    cases.forEach((raw, kind) {
      test('${kind.name} <- ${raw.substring(0, raw.length < 50 ? raw.length : 50)}', () => expect(DownloadError.classify(raw).kind, kind));
    });

    test('unknown errors keep the last ERROR line and are retryable', () {
      final e = DownloadError.classify('[info] x\nERROR: something odd happened\n');
      expect(e.kind, DownloadErrorKind.unknown);
      expect(e.message, 'ERROR: something odd happened');
      expect(e.retryable, isTrue);
    });

    test('actionable hints exist for the common failures', () {
      expect(DownloadError.classify('Sign in to confirm you’re not a bot').hint, contains('cookies'));
      expect(DownloadError.classify('Unable to extract').hint, contains('Update'));
    });
  });
}
