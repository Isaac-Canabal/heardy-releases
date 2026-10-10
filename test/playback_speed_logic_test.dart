import 'package:flutter_test/flutter_test.dart';
import 'package:heardy/services/playback_speed_logic.dart';

void main() {
  test('clamp keeps the value in range and snaps to the step', () {
    expect(normalizePlaybackRate(0.1), minPlaybackRate);
    expect(normalizePlaybackRate(5), maxPlaybackRate);
    expect(normalizePlaybackRate(1.02), 1.0);
    expect(normalizePlaybackRate(1.03), 1.05);
    expect(normalizePlaybackRate(1.5), 1.5);
  });

  test('non finite values fall back to 1.0', () {
    expect(normalizePlaybackRate(double.nan), 1.0);
    expect(normalizePlaybackRate(double.infinity), 1.0);
  });

  test('presets are inside the range and include 1.0', () {
    expect(playbackSpeedPresets, contains(1.0));
    for (final p in playbackSpeedPresets) {
      expect(p, inInclusiveRange(minPlaybackRate, maxPlaybackRate));
    }
    expect(playbackSpeedPresets.first, minPlaybackRate);
    expect(playbackSpeedPresets.last, maxPlaybackRate);
  });

  test('labels drop trailing zeros', () {
    expect(playbackRateLabel(1.0), '1x');
    expect(playbackRateLabel(1.5), '1.5x');
    expect(playbackRateLabel(0.75), '0.75x');
    expect(playbackRateLabel(2.0), '2x');
  });

  test('isDefaultPlayback', () {
    expect(isDefaultPlayback(1.0, 1.0), isTrue);
    expect(isDefaultPlayback(1.25, 1.0), isFalse);
    expect(isDefaultPlayback(1.0, 0.9), isFalse);
  });
}
