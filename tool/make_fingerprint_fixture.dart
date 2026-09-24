// ignore_for_file: avoid_print
// Regenerates test/fixtures/synth_melody_fpcalc.txt with the reference fpcalc:
//   dart run tool/make_fingerprint_fixture.dart path/to/fpcalc
import 'dart:io';

import '../test/helpers/synth.dart';

Future<void> main(List<String> args) async {
  final fpcalc = args.isEmpty ? 'fpcalc' : args.first;
  final wav = File('${Directory.systemTemp.path}/synth_melody.wav');
  wav.writeAsBytesSync(wavBytes(toInt16(synthMelody()), 44100));
  final r = await Process.run(fpcalc, ['-raw', wav.path]);
  final line = (r.stdout as String).split('\n').firstWhere((l) => l.startsWith('FINGERPRINT='));
  File('test/fixtures/synth_melody_fpcalc.txt').writeAsStringSync('${line.substring('FINGERPRINT='.length).trim()}\n');
  print('wrote fixture (${line.split(',').length} sub-fingerprints)');
}
