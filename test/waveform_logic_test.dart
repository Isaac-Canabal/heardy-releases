import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:heardy/services/waveform_logic.dart';

void main() {
  group('downsampleAmplitudes', () {
    test('toma el pico de cada tramo', () {
      final out = downsampleAmplitudes([1, 5, 2, 3, 9, 0], 3);
      expect(out, [5, 3, 9]);
    });

    test('con menos muestras que barras las repite por posición', () {
      final out = downsampleAmplitudes([1, 2], 4);
      expect(out, [1, 1, 2, 2]);
    });

    test('vacío o barras inválidas', () {
      expect(downsampleAmplitudes([], 3), [0, 0, 0]);
      expect(downsampleAmplitudes([1], 0), isEmpty);
    });

    test('ignora NaN e infinitos', () {
      final out = downsampleAmplitudes([double.nan, 2, double.infinity, 1], 2);
      expect(out, [2, 1]);
    });
  });

  group('normalizeToBytes', () {
    test('el máximo queda en 255 y el resto proporcional', () {
      final out = normalizeToBytes([0, 0.5, 1.0]);
      expect(out, [0, 128, 255]);
    });

    test('silencio total da ceros', () {
      expect(normalizeToBytes([0, 0, 0]), [0, 0, 0]);
    });
  });

  group('codec con cabecera de versión', () {
    test('ida y vuelta', () {
      final peaks = Uint8List.fromList(List.generate(200, (i) => i));
      expect(decodeWaveform(encodeWaveform(peaks)), peaks);
    });

    test('rechaza magia, versión o largo incorrectos', () {
      final good = encodeWaveform(Uint8List.fromList([1, 2, 3]));
      expect(decodeWaveform(Uint8List(0)), isNull);

      final badMagic = Uint8List.fromList(good)..[0] = 0;
      expect(decodeWaveform(badMagic), isNull);

      final badVersion = Uint8List.fromList(good)..[3] = 99;
      expect(decodeWaveform(badVersion), isNull);

      final truncated = Uint8List.fromList(good.sublist(0, good.length - 1));
      expect(decodeWaveform(truncated), isNull);
    });
  });

  group('mapeo posición <-> x', () {
    test('x a fracción con límites', () {
      expect(positionToFraction(50, 200), 0.25);
      expect(positionToFraction(-10, 200), 0);
      expect(positionToFraction(500, 200), 1);
      expect(positionToFraction(10, 0), 0);
    });

    test('fracción a duración y de vuelta', () {
      const d = Duration(minutes: 3);
      expect(fractionToDuration(0.5, d), const Duration(seconds: 90));
      expect(fractionToDuration(2, d), d);
      expect(durationToFraction(const Duration(seconds: 45), d), 0.25);
      expect(durationToFraction(const Duration(seconds: 5), Duration.zero), 0);
    });
  });
}
