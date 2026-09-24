import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/features/lyrics/lrc_parser.dart';

void main() {
  test('parses timestamps in all common shapes', () {
    final d = LrcDocument.parse('''
[00:01.5]half second fraction
[00:02.50]two decimals
[00:03.500]three decimals
[00:04]no fraction
[00:05:25]colon fraction
[01:02:03.04]with hours
[100:00.00]long track
''');
    expect(d.lines.map((l) => l.time.inMilliseconds), [1500, 2500, 3500, 4000, 5250, 3723040, 6000000]);
    expect(d.lines[0].text, 'half second fraction');
  });

  test('"05" fraction means 50 ms, not 5 ms', () {
    expect(LrcDocument.parse('[00:01.05]x').lines.single.time.inMilliseconds, 1050);
  });

  test('repeated timestamps create one line per stamp, sorted', () {
    final d = LrcDocument.parse('[00:10.00][00:50.00]chorus\n[00:20.00]verse');
    expect(d.lines.map((l) => '${l.time.inSeconds}:${l.text}'), ['10:chorus', '20:verse', '50:chorus']);
  });

  test('reads metadata tags and offset, ignores unstamped text', () {
    final d = LrcDocument.parse('[ar:Artist]\n[ti:Song]\n[offset:+250]\nCredits here\n[00:01.00]hi');
    expect(d.tags['ar'], 'Artist');
    expect(d.tags['ti'], 'Song');
    expect(d.offsetMs, 250);
    expect(d.lines, hasLength(1));
  });

  test('strips enhanced word timestamps', () {
    final d = LrcDocument.parse('[00:01.00]<00:01.00>Hello <00:01.50>world');
    expect(d.lines.single.text, 'Hello world');
  });

  test('keeps empty lines (instrumental breaks) so the highlight can clear', () {
    final d = LrcDocument.parse('[00:01.00]sing\n[00:05.00]\n[00:09.00]sing again');
    expect(d.lines[1].text, '');
  });

  test('handles CRLF, BOM and blank lines', () {
    final d = LrcDocument.parse('﻿[00:01.00]a\r\n\r\n[00:02.00]b\r\n');
    expect(d.lines.map((l) => l.text), ['a', 'b']);
  });

  test('sorts unsorted input and keeps duplicates of the same time in file order', () {
    final d = LrcDocument.parse('[00:05.00]late\n[00:01.00]first\n[00:01.00]second');
    expect(d.lines.map((l) => l.text), ['first', 'second', 'late']);
  });

  group('indexAt', () {
    final d = LrcDocument.parse('[00:01.00]a\n[00:05.00]b\n[00:09.00]c');

    test('before the first line is -1', () => expect(d.indexAt(const Duration(milliseconds: 500)), -1));
    test('on the boundary selects that line', () => expect(d.indexAt(const Duration(seconds: 5)), 1));
    test('between lines selects the earlier one', () => expect(d.indexAt(const Duration(seconds: 7)), 1));
    test('after the end selects the last', () => expect(d.indexAt(const Duration(minutes: 5)), 2));
    test('user offset delays the lyrics', () {
      // Lyrics shown 2 s later than the raw timestamps.
      expect(d.indexAt(const Duration(seconds: 5), userOffsetMs: 2000), 0);
      expect(d.indexAt(const Duration(seconds: 7), userOffsetMs: 2000), 1);
    });
    test('file offset makes lyrics appear earlier', () {
      final o = LrcDocument.parse('[offset:1000]\n[00:05.00]x');
      expect(o.indexAt(const Duration(seconds: 4)), 0);
      expect(o.indexAt(const Duration(milliseconds: 3900)), -1);
    });
    test('empty document', () => expect(LrcDocument.empty.indexAt(const Duration(seconds: 1)), -1));
  });

  test('seekTimeFor reverses the offsets and never goes negative', () {
    final d = LrcDocument.parse('[00:01.00]a');
    expect(d.seekTimeFor(0), const Duration(seconds: 1));
    expect(d.seekTimeFor(0, userOffsetMs: 500), const Duration(milliseconds: 1500));
    expect(d.seekTimeFor(0, userOffsetMs: -5000), Duration.zero);
  });

  test('looksSynced distinguishes plain text from LRC', () {
    expect(LrcDocument.looksSynced('[00:01.00]hi'), isTrue);
    expect(LrcDocument.looksSynced('just words\non lines'), isFalse);
    expect(LrcDocument.looksSynced('[ar:Someone]'), isFalse);
  });
}
