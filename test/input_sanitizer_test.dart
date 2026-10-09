import 'package:flutter_test/flutter_test.dart';
import 'package:heardy/services/input_sanitizer.dart';

void main() {
  group('sanitizeSearchInput', () {
    test('recorta y colapsa espacios y saltos de línea', () {
      expect(sanitizeSearchInput('  hola \n\t  mundo  '), 'hola mundo');
    });

    test('elimina caracteres de control y nulos', () {
      expect(sanitizeSearchInput('a\x00b\x07c\x7Fd'), 'abcd');
    });

    test('elimina bidi y ancho cero', () {
      expect(sanitizeSearchInput('a\u202Eb\u200Bc\u2066d\uFEFFe'), 'abcde');
    });

    test('deja pasar texto con etiquetas como texto, sin alterarlo', () {
      expect(sanitizeSearchInput('<script>alert(1)</script>'), '<script>alert(1)</script>');
    });

    test('conserva acentos, ñ, comillas y emojis', () {
      const s = 'Canción "niño" ¿qué? 🎵 café';
      expect(sanitizeSearchInput(s), s);
    });

    test('conserva emojis compuestos con unidor', () {
      const family = '👨\u200D👩\u200D👧';
      expect(sanitizeSearchInput(family), family);
    });

    test('limita la longitud sin partir pares sustitutos', () {
      final out = sanitizeSearchInput('🎵' * 300);
      expect(out.runes.length, maxSearchInputLength);
      expect(out.runes.every((r) => r == 0x1F3B5), isTrue);
    });

    test('usernames: 64 como máximo', () {
      expect(sanitizeUsernameInput('a' * 100).length, 64);
    });

    test('vacío y solo basura dan cadena vacía', () {
      expect(sanitizeSearchInput(''), '');
      expect(sanitizeSearchInput(' \u200B\x00 '), '');
    });
  });

  group('canRunUserSearch', () {
    final t0 = DateTime(2026, 1, 1, 12);

    test('rechaza textos de menos de 3 caracteres', () {
      expect(canRunUserSearch('ab', null, t0), isFalse);
      expect(canRunUserSearch('abc', null, t0), isTrue);
    });

    test('rechaza una búsqueda dentro de los 400 ms de la anterior', () {
      expect(canRunUserSearch('isaac', t0, t0.add(const Duration(milliseconds: 399))), isFalse);
      expect(canRunUserSearch('isaac', t0, t0.add(const Duration(milliseconds: 400))), isTrue);
    });
  });
}
