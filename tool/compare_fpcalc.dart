// ignore_for_file: avoid_print
// Validates the Dart Chromaprint port against the reference `fpcalc` binary.
//
//   dart run tool/compare_fpcalc.dart path/to/audio.ogg [--fpcalc path/to/fpcalc] [--ffmpeg path/to/ffmpeg]
//
// Prints the bit similarity between both fingerprints. Two different encodings of the same
// audio typically score 0.90+; unrelated audio scores about 0.50.
import 'dart:io';
import 'dart:typed_data';

import 'package:musicplayer/features/metadata/chromaprint.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/compare_fpcalc.dart <audio> [--fpcalc exe] [--ffmpeg exe] [--rate 44100]');
    exit(64);
  }
  final file = args.first;
  String opt(String name, String def) {
    final i = args.indexOf(name);
    return i >= 0 && i + 1 < args.length ? args[i + 1] : def;
  }

  final fpcalc = opt('--fpcalc', 'fpcalc');
  final ffmpeg = opt('--ffmpeg', 'ffmpeg');
  final rate = int.parse(opt('--rate', '44100'));

  final ref = await Process.run(fpcalc, ['-raw', '-length', '120', file]);
  if (ref.exitCode != 0) {
    stderr.writeln('fpcalc failed: ${ref.stderr}');
    exit(1);
  }
  final line = (ref.stdout as String).split('\n').firstWhere((l) => l.startsWith('FINGERPRINT='));
  final reference = line.substring('FINGERPRINT='.length).trim().split(',').map(int.parse).map((v) => v & 0xFFFFFFFF).toList();

  final pcm = await Process.start(ffmpeg, ['-v', 'error', '-i', file, '-t', '120', '-ac', '2', '-ar', '$rate', '-f', 's16le', '-']);
  final builder = BytesBuilder(copy: false);
  await pcm.stdout.forEach(builder.add);
  await pcm.exitCode;

  final sw = Stopwatch()..start();
  final mine = Chromaprint.fingerprintPcm16(builder.takeBytes(), rate, channels: 2);
  sw.stop();

  final n = mine.length < reference.length ? mine.length : reference.length;
  print('fpcalc : ${reference.length} sub-fingerprints');
  print('dart   : ${mine.length} sub-fingerprints (${sw.elapsedMilliseconds} ms)');
  print('first  : fpcalc=${reference.take(3).toList()} dart=${mine.take(3).toList()}');
  print('common : $n frames, bit similarity ${Chromaprint.similarity(mine, reference).toStringAsFixed(4)}');
  final compressed = Chromaprint.encode(reference);
  final roundTrip = Chromaprint.decode(compressed);
  print('codec  : encode/decode round trip ${roundTrip.length == reference.length && List.generate(reference.length, (i) => roundTrip[i] == reference[i]).every((e) => e) ? 'OK' : 'MISMATCH'}');
}
