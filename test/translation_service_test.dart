import 'package:flutter_test/flutter_test.dart';
import 'package:heardy/services/translation_service.dart';

void main() {
  group('detectLyricsLanguage', () {
    test('detecta español por palabras funcionales', () {
      expect(
        detectLyricsLanguage('Que no puedo vivir sin ti, esto es todo lo que tengo'),
        'es',
      );
    });

    test('detecta inglés por palabras funcionales', () {
      expect(
        detectLyricsLanguage('I know that you and I are never gonna be the same'),
        'en',
      );
    });

    test('un texto vacío o sin palabras reconocibles cae al valor por defecto', () {
      expect(detectLyricsLanguage(''), 'en');
      expect(detectLyricsLanguage('mmm mmm woah woah'), 'en');
    });
  });
}
