import 'package:flutter_test/flutter_test.dart';
import 'package:heardy/services/repeat_count_logic.dart';

void main() {
  test('inactive by default', () {
    final c = RepeatCounter();
    expect(c.isActive, isFalse);
    expect(c.remaining, 0);
    expect(c.onWrap(), isFalse);
  });

  test('start(3): stays active for two wraps and finishes on the third', () {
    final c = RepeatCounter()..start(3);
    expect(c.isActive, isTrue);
    expect(c.remaining, 3);
    expect(c.onWrap(), isTrue);
    expect(c.remaining, 2);
    expect(c.onWrap(), isTrue);
    expect(c.remaining, 1);
    expect(c.onWrap(), isFalse);
    expect(c.isActive, isFalse);
    expect(c.remaining, 0);
  });

  test('cancel resets', () {
    final c = RepeatCounter()..start(5);
    c.cancel();
    expect(c.isActive, isFalse);
    expect(c.onWrap(), isFalse);
  });

  test('start clamps to the allowed range', () {
    expect(clampRepeatCount(0), 1);
    expect(clampRepeatCount(4), 4);
    expect(clampRepeatCount(10000), maxRepeatCount);
    expect((RepeatCounter()..start(-2)).remaining, 1);
  });
}
