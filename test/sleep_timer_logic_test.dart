import 'package:flutter_test/flutter_test.dart';
import 'package:heardy/services/sleep_timer_logic.dart';

void main() {
  test('inactive by default and onTrackEnded does nothing', () {
    final c = TrackSleepCounter();
    expect(c.isActive, isFalse);
    expect(c.remaining, isNull);
    expect(c.onTrackEnded(), isFalse);
  });

  test('N=1 stops when the current track ends', () {
    final c = TrackSleepCounter()..start(1);
    expect(c.remaining, 1);
    expect(c.onTrackEnded(), isTrue);
    expect(c.isActive, isFalse);
  });

  test('N=3 stops at the end of the third track', () {
    final c = TrackSleepCounter()..start(3);
    expect(c.onTrackEnded(), isFalse);
    expect(c.remaining, 2);
    expect(c.onTrackEnded(), isFalse);
    expect(c.remaining, 1);
    expect(c.onTrackEnded(), isTrue);
    expect(c.remaining, isNull);
  });

  test('cancel deactivates', () {
    final c = TrackSleepCounter()..start(2);
    c.cancel();
    expect(c.isActive, isFalse);
    expect(c.onTrackEnded(), isFalse);
  });

  test('start clamps to the allowed range', () {
    expect(clampSleepTracks(0), 1);
    expect(clampSleepTracks(-5), 1);
    expect(clampSleepTracks(7), 7);
    expect(clampSleepTracks(9999), maxSleepTracks);
    final c = TrackSleepCounter()..start(0);
    expect(c.remaining, 1);
  });
}
