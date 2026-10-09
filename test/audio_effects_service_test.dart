// Sólo la lógica pura: interpolación de ganancias por preset y armado del
// filtro `af` de mpv. Nada de esto toca `just_audio`/`media_kit`, así que no
// necesita un dispositivo ni un backend real (mismo criterio que
// test/spotify_match_test.dart o test/lyrics_service_test.dart).
import 'package:flutter_test/flutter_test.dart';

import 'package:heardy/services/audio_effects_service.dart';

void main() {
  group('gainForFrequency', () {
    test('devuelve el valor exacto en un punto de control', () {
      const curve = [MapEntry(60.0, -2.0), MapEntry(910.0, 4.0)];
      expect(gainForFrequency(curve, 60), -2.0);
      expect(gainForFrequency(curve, 910), 4.0);
    });

    test('interpola en escala logarítmica entre dos puntos', () {
      const curve = [MapEntry(100.0, 0.0), MapEntry(10000.0, 10.0)];
      // sqrt(100*10000) = 1000, el punto medio en escala log
      expect(gainForFrequency(curve, 1000), closeTo(5.0, 0.001));
    });

    test('satura al valor del extremo fuera de rango', () {
      const curve = [MapEntry(60.0, -2.0), MapEntry(910.0, 4.0)];
      expect(gainForFrequency(curve, 20), -2.0);
      expect(gainForFrequency(curve, 20000), 4.0);
    });

    test('curva vacía siempre da ganancia 0', () {
      expect(gainForFrequency(const [], 1000), 0);
    });
  });

  group('gainsForPreset', () {
    test('flat da ganancia 0 en cualquier banda', () {
      final gains = gainsForPreset(EqualizerPreset.flat, windowsEqBands);
      expect(gains, everyElement(0.0));
    });

    test('devuelve una ganancia por cada frecuencia pedida', () {
      final gains = gainsForPreset(EqualizerPreset.vocalBoost, windowsEqBands);
      expect(gains, hasLength(windowsEqBands.length));
    });

    test('vocalBoost realza medios más que graves o agudos extremos', () {
      final gains = gainsForPreset(EqualizerPreset.vocalBoost, windowsEqBands);
      final midGain = gains[2]; // 910 Hz
      expect(midGain, greaterThan(gains[0])); // más que 60 Hz
      expect(midGain, greaterThan(gains[4])); // más que 14000 Hz
    });

    test('trebleFocus realza agudos más que graves', () {
      final gains = gainsForPreset(EqualizerPreset.trebleFocus, windowsEqBands);
      expect(gains.last, greaterThan(gains.first));
    });
  });

  group('buildWindowsAudioFilter', () {
    test('sin nada habilitado, no hay filtro', () {
      final filter = buildWindowsAudioFilter(
        stabilizeEnabled: false,
        equalizerEnabled: false,
        gains: const [],
      );
      expect(filter, isNull);
    });

    test('estabilizar solo agrega dynaudnorm', () {
      final filter = buildWindowsAudioFilter(
        stabilizeEnabled: true,
        equalizerEnabled: false,
        gains: const [],
      );
      expect(filter, 'dynaudnorm');
    });

    test('ecualizador agrega una etapa equalizer= por banda con ganancia no nula', () {
      final filter = buildWindowsAudioFilter(
        stabilizeEnabled: false,
        equalizerEnabled: true,
        gains: const [0, 3, 0, -2, 0],
      );
      expect(filter, isNotNull);
      expect(filter, contains('equalizer=f=230'));
      expect(filter, contains('equalizer=f=3600'));
      expect(filter, isNot(contains('f=60:')));
      expect(filter, isNot(contains('f=910:')));
      expect(filter, isNot(contains('f=14000:')));
    });

    test('estabilizar + ecualizador se combinan con coma', () {
      final filter = buildWindowsAudioFilter(
        stabilizeEnabled: true,
        equalizerEnabled: true,
        gains: const [1, 0, 0, 0, 0],
      );
      expect(filter, startsWith('dynaudnorm,equalizer=f=60'));
    });
  });
}
