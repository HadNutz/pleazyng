import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/companion_remote/listening_clock.dart';

void main() {
  const file = (server: 'srv', item: '42', source: 'edition-2', part: 9);
  const clock = ListeningClock(file, Duration(seconds: 50), true, 1.5);
  test('probes preserve exact file and part, and project elapsed time at the host rate', () {
    final data = clock.toJson();
    expect(ListeningClock.parse(data)?.file, file);
    expect(
      clock.target(const Duration(milliseconds: 200), const Duration(milliseconds: 100)),
      const Duration(milliseconds: 50400),
    );
    expect(
      const ListeningClock(
        file,
        Duration(seconds: 50),
        false,
        1.5,
      ).target(const Duration(seconds: 1), const Duration(milliseconds: 100)),
      const Duration(seconds: 50),
    );
    for (final bad in [
      {'source': 'https://example.test/a'},
      {'ms': -1},
      {'rate': double.nan},
      {'playing': 1},
      {'part': 'other'},
    ]) {
      expect(ListeningClock.parse({...data, ...bad}), isNull);
    }
  });
  test('natural jitter, drift, scrubbing and headphone reconnection have distinct responses', () {
    const ms = Duration(milliseconds: 20);
    expect(listeningCorrection(ms, playing: true, rate: 1), (seek: false, speed: 1.0));
    expect(listeningCorrection(const Duration(milliseconds: 120), playing: true, rate: 1).speed, greaterThan(1));
    expect(listeningCorrection(const Duration(milliseconds: -120), playing: true, rate: 1).speed, lessThan(1));
    expect(listeningCorrection(const Duration(seconds: 20), playing: false, rate: 1).seek, isTrue);
    expect(listeningCorrection(ms, playing: true, rate: 1, resync: true).seek, isTrue);
  });
}
