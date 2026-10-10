import 'package:flutter_test/flutter_test.dart';
import 'package:heardy/services/lyrics_logic.dart';
import 'package:heardy/services/lyrics_service.dart';

void main() {
  const start = Duration(seconds: 10);

  group('parseLyricText', () {
    test('sin etiquetas devuelve el texto y ninguna palabra', () {
      final r = parseLyricText('Hola mundo', start);
      expect(r.text, 'Hola mundo');
      expect(r.words, isEmpty);
      expect(r.end, isNull);
    });

    test('extrae palabras con su tiempo y el cierre final', () {
      final r = parseLyricText(
        '<00:10.00>Hola <00:10.50>mundo <00:11.20>',
        start,
      );
      expect(r.text, 'Hola mundo');
      expect(r.words.map((w) => w.text).toList(), ['Hola ', 'mundo ']);
      expect(r.words[0].start, const Duration(seconds: 10));
      expect(r.words[1].start, const Duration(seconds: 10, milliseconds: 500));
      expect(r.end, const Duration(seconds: 11, milliseconds: 200));
    });

    test('texto antes de la primera etiqueta arranca al inicio de la linea', () {
      final r = parseLyricText('Oh <00:10.40>yeah', start);
      expect(r.words.first.text, 'Oh ');
      expect(r.words.first.start, start);
      expect(r.words.last.text, 'yeah');
      expect(r.text, 'Oh yeah');
    });

    test('etiquetas sin texto no generan palabras', () {
      final r = parseLyricText('<00:10.00><00:11.00>', start);
      expect(r.words, isEmpty);
      expect(r.text, '');
    });
  });

  group('wordProgressAt', () {
    final words = [
      LyricWord(const Duration(seconds: 10), 'Hola '),
      LyricWord(const Duration(seconds: 11), 'mundo'),
    ];
    const end = Duration(seconds: 13);

    test('antes de la primera palabra no hay activa', () {
      final p = wordProgressAt(words, end, const Duration(seconds: 9));
      expect(p.index, -1);
      expect(p.progress, 0);
    });

    test('a mitad de una palabra da progreso fraccional', () {
      final p = wordProgressAt(
        words,
        end,
        const Duration(seconds: 10, milliseconds: 500),
      );
      expect(p.index, 0);
      expect(p.progress, closeTo(0.5, 1e-9));
    });

    test('la ultima palabra usa el cierre de la linea', () {
      final p = wordProgressAt(words, end, const Duration(seconds: 12));
      expect(p.index, 1);
      expect(p.progress, closeTo(0.5, 1e-9));
    });

    test('pasado el cierre queda completa', () {
      final p = wordProgressAt(words, end, const Duration(seconds: 20));
      expect(p.index, 1);
      expect(p.progress, 1);
    });

    test('sin palabras no hay activa', () {
      final p = wordProgressAt(const [], end, const Duration(seconds: 12));
      expect(p.index, -1);
    });
  });

  group('parseLrc con LRC enriquecido', () {
    final service = LyricsService.instance;

    test('quita las etiquetas del texto y conserva las palabras', () {
      final lines = service.parseLrc(
        '[00:10.00]<00:10.00>Hola <00:10.50>mundo <00:11.20>\n[00:12.00]Plana',
      );
      expect(lines, hasLength(2));
      expect(lines[0].text, 'Hola mundo');
      expect(lines[0].words, hasLength(2));
      expect(lines[0].wordsEnd, const Duration(seconds: 11, milliseconds: 200));
      expect(lines[1].text, 'Plana');
      expect(lines[1].words, isEmpty);
    });
  });
}
