import 'package:flutter_test/flutter_test.dart';
import 'package:heardy/services/fade_logic.dart';

void main() {
  const fade = Duration(seconds: 3);
  const duration = Duration(minutes: 3);

  group('trackFadeGain', () {
    test('en medio de la pista es 1.0', () {
      expect(trackFadeGain(const Duration(minutes: 1), duration, fade), 1.0);
    });

    test('sube desde 0 al inicio', () {
      expect(trackFadeGain(Duration.zero, duration, fade), 0.0);
      expect(
        trackFadeGain(const Duration(milliseconds: 1500), duration, fade),
        closeTo(0.5, 1e-9),
      );
      expect(trackFadeGain(fade, duration, fade), 1.0);
    });

    test('baja hasta 0 al final', () {
      expect(
        trackFadeGain(duration - const Duration(milliseconds: 1500), duration, fade),
        closeTo(0.5, 1e-9),
      );
      expect(trackFadeGain(duration, duration, fade), 0.0);
    });

    test('sin fundido o sin duracion conocida no toca el volumen', () {
      expect(trackFadeGain(Duration.zero, duration, Duration.zero), 1.0);
      expect(trackFadeGain(Duration.zero, Duration.zero, fade), 1.0);
    });

    test('pistas demasiado cortas no se funden', () {
      expect(
        trackFadeGain(const Duration(seconds: 1), const Duration(seconds: 8), fade),
        1.0,
      );
    });
  });

  group('shouldApplyGain', () {
    test('ignora cambios minimos', () {
      expect(shouldApplyGain(0.50, 0.51), isFalse);
      expect(shouldApplyGain(0.50, 0.60), isTrue);
    });

    test('siempre aplica al llegar a los extremos', () {
      expect(shouldApplyGain(0.99, 1.0), isTrue);
      expect(shouldApplyGain(0.01, 0.0), isTrue);
      expect(shouldApplyGain(1.0, 1.0), isFalse);
    });
  });
}
