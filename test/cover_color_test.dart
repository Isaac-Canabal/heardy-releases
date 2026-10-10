import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/painting.dart' show HSLColor;
import 'package:flutter_test/flutter_test.dart';

import 'package:heardy/services/cover_color.dart';

Uint8List _solid(Color c, int count, {int alpha = 255}) {
  final out = Uint8List(count * 4);
  for (var i = 0; i < count; i++) {
    out[i * 4] = (c.r * 255).round();
    out[i * 4 + 1] = (c.g * 255).round();
    out[i * 4 + 2] = (c.b * 255).round();
    out[i * 4 + 3] = alpha;
  }
  return out;
}

Uint8List _concat(List<Uint8List> parts) =>
    Uint8List.fromList([for (final p in parts) ...p]);

double _hue(Color c) => HSLColor.fromColor(c).hue;

void main() {
  group('accentFromRgba', () {
    test('devuelve null sin píxeles útiles', () {
      expect(accentFromRgba(Uint8List(0)), isNull);
      expect(accentFromRgba(_solid(const Color(0xFF3366FF), 50, alpha: 0)), isNull);
    });

    test('ignora casi negro y casi blanco', () {
      final px = _concat([
        _solid(const Color(0xFF020202), 500),
        _solid(const Color(0xFFFDFDFD), 500),
        _solid(const Color(0xFFD02020), 20),
      ]);
      final c = accentFromRgba(px)!;
      expect(_hue(c), closeTo(0, 10));
    });

    test('prefiere el color vivo al gris aunque el gris abunde', () {
      final px = _concat([
        _solid(const Color(0xFF808080), 300),
        _solid(const Color(0xFF2040E0), 200),
      ]);
      final c = accentFromRgba(px)!;
      expect(_hue(c), closeTo(230, 15));
    });

    test('con una carátula sólo gris devuelve un gris legible', () {
      final c = accentFromRgba(_solid(const Color(0xFF909090), 100))!;
      expect(HSLColor.fromColor(c).saturation, lessThan(0.1));
      expect(contrastWithWhite(c), greaterThanOrEqualTo(minAccentContrast));
    });
  });

  group('clampAccent', () {
    test('oscurece un amarillo brillante hasta contraste legible con blanco', () {
      const yellow = Color(0xFFFFFF00);
      expect(contrastWithWhite(yellow), lessThan(minAccentContrast));
      final c = clampAccent(yellow);
      expect(contrastWithWhite(c), greaterThanOrEqualTo(minAccentContrast));
      expect(_hue(c), closeTo(60, 3));
    });

    test('aclara un casi negro para que no desaparezca', () {
      final c = clampAccent(const Color(0xFF000000));
      expect(HSLColor.fromColor(c).lightness, greaterThanOrEqualTo(minAccentLightness - 0.001));
    });

    test('deja intacto un color ya dentro del rango', () {
      const mid = Color(0xFF2A4BA0);
      expect(clampAccent(mid).toARGB32(), mid.toARGB32());
    });
  });
}
