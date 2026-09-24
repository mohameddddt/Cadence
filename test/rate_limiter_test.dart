import 'package:flutter_test/flutter_test.dart';
import 'package:musicplayer/core/net/rate_limiter.dart';

void main() {
  group('HostRateLimiter', () {
    late DateTime now;
    late List<Duration> waits;
    late HostRateLimiter limiter;

    setUp(() {
      now = DateTime(2024, 1, 1);
      waits = [];
      limiter = HostRateLimiter(
        intervals: {'slow.example': const Duration(seconds: 1)},
        now: () => now,
        // Real time passes while callers wait; the fake keeps the clock where the
        // test puts it so the reserved slots are visible.
        delay: (d) async => waits.add(d),
      );
    });

    test('spaces a burst of requests one interval apart, in order', () async {
      final order = <int>[];
      await Future.wait([
        for (var i = 0; i < 4; i++) limiter.acquire('slow.example').then((_) => order.add(i)),
      ]);
      expect(waits, [
        const Duration(seconds: 1),
        const Duration(seconds: 2),
        const Duration(seconds: 3),
      ]);
      expect(order, [0, 1, 2, 3]);
    });

    test('first request is immediate and later ones after idling are too', () async {
      await limiter.acquire('slow.example');
      expect(waits, isEmpty);
      now = now.add(const Duration(seconds: 5));
      await limiter.acquire('slow.example');
      expect(waits, isEmpty);
    });

    test('hosts are independent and unknown hosts are unlimited', () async {
      await limiter.acquire('slow.example');
      await limiter.acquire('other.example');
      await limiter.acquire('other.example');
      expect(waits, isEmpty);
    });

    test('MusicBrainz default stays above one request per second', () {
      expect(HostRateLimiter.defaultIntervals['musicbrainz.org']!.inMilliseconds, greaterThanOrEqualTo(1000));
    });
  });
}
