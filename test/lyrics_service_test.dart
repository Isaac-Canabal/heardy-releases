// Sólo lo que se puede probar sin red: el parseo de .lrc (puro) y el
// emparejamiento por duración de candidatos de NetEase (función top-level
// pura, misma razón que test/spotify_match_test.dart no llama a la red).
import 'package:flutter_test/flutter_test.dart';

import 'package:heardy/services/lyrics_service.dart';

void main() {
  group('parseLrc', () {
    final service = LyricsService.instance;

    test('parsea centisegundos (2 dígitos) correctamente', () {
      final lines = service.parseLrc('[00:12.34]Primera línea');
      expect(lines, hasLength(1));
      expect(lines.single.time, const Duration(seconds: 12, milliseconds: 340));
      expect(lines.single.text, 'Primera línea');
    });

    test('parsea milisegundos (3 dígitos) correctamente', () {
      final lines = service.parseLrc('[01:02.345]Otra línea');
      expect(lines.single.time, const Duration(minutes: 1, seconds: 2, milliseconds: 345));
    });

    test('ordena las líneas por tiempo aunque el .lrc venga desordenado', () {
      final lines = service.parseLrc('[00:10.00]B\n[00:05.00]A\n[00:20.00]C');
      expect(lines.map((l) => l.text).toList(), ['A', 'B', 'C']);
    });

    test('ignora líneas sin marca de tiempo (letra plana, sin sincronizar)', () {
      final lines = service.parseLrc('Sólo texto\nSin timestamps');
      expect(lines, isEmpty);
    });
  });

  group('pickNeteaseCandidate', () {
    List<dynamic> songs(List<int> durationsMs) =>
        [for (final d in durationsMs) {'id': d, 'duration': d}];

    test('elige el candidato con duración más cercana', () {
      final match = pickNeteaseCandidate(songs([180000, 210000, 205000]), 200);
      expect(match!['duration'], 205000);
    });

    test('descarta candidatos fuera de la tolerancia máxima', () {
      final match = pickNeteaseCandidate(songs([260000]), 200, maxToleranceSeconds: 30);
      expect(match, isNull);
    });

    test('sin duración objetivo conocida, se queda con el primer resultado', () {
      final match = pickNeteaseCandidate(songs([180000, 210000]), 0);
      expect(match!['duration'], 180000);
    });

    test('sin resultados, no hay candidato', () {
      expect(pickNeteaseCandidate(const [], 200), isNull);
    });
  });
}
