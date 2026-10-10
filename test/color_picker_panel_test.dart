import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heardy/widgets/color_picker_panel.dart';

void main() {
  group('helpers HSV', () {
    test('hsvToColor de colores conocidos', () {
      expect(hsvToColor(0, 1, 1).toARGB32(), 0xFFFF0000);
      expect(hsvToColor(120, 1, 1).toARGB32(), 0xFF00FF00);
      expect(hsvToColor(240, 1, 1).toARGB32(), 0xFF0000FF);
      expect(hsvToColor(0, 0, 1).toARGB32(), 0xFFFFFFFF);
      expect(hsvToColor(0, 0, 0).toARGB32(), 0xFF000000);
    });

    test('colorToHsv de colores conocidos', () {
      final h = colorToHsv(const Color(0xFF0000FF));
      expect(h.hue, closeTo(240, 0.01));
      expect(h.saturation, closeTo(1, 0.001));
      expect(h.value, closeTo(1, 0.001));
    });

    test('ida y vuelta conserva el color', () {
      for (final v in [0xFF3B82F6, 0xFFEC4899, 0xFF64748B, 0xFF123456]) {
        final c = Color(v);
        final h = colorToHsv(c);
        expect(hsvToColor(h.hue, h.saturation, h.value).toARGB32(), v);
      }
    });

    test('hsvToColor acota los valores fuera de rango', () {
      expect(hsvToColor(400, 2, 2).toARGB32(), hsvToColor(360, 1, 1).toARGB32());
      expect(hsvToColor(-10, -1, -1).toARGB32(), 0xFF000000);
    });
  });

  Widget host(Color value, ValueChanged<Color> onChanged) => MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: ColorPickerPanel(
                color: value,
                onChanged: onChanged,
                hueLabel: 'Tono',
                saturationValueLabel: 'Saturacion y brillo',
              ),
            ),
          ),
        ),
      );

  testWidgets('tocar el cuadrado emite un color', (tester) async {
    Color? got;
    await tester.pumpWidget(host(const Color(0xFFFF0000), (c) => got = c));
    final square = find.byKey(const ValueKey('picker-sv'));
    final rect = tester.getRect(square);
    await tester.tapAt(rect.topLeft + const Offset(1, 1));
    expect(got, isNotNull);
    // Arriba a la izquierda: poca saturacion, brillo maximo -> casi blanco.
    final h = colorToHsv(got!);
    expect(h.value, greaterThan(0.95));
    expect(h.saturation, lessThan(0.1));
  });

  testWidgets('arrastrar el cuadrado hasta abajo da casi negro', (tester) async {
    Color? got;
    await tester.pumpWidget(host(const Color(0xFFFF0000), (c) => got = c));
    final rect = tester.getRect(find.byKey(const ValueKey('picker-sv')));
    final g = await tester.startGesture(rect.center);
    await g.moveTo(rect.bottomRight - const Offset(1, 1));
    await g.up();
    expect(got, isNotNull);
    expect(colorToHsv(got!).value, lessThan(0.05));
  });

  testWidgets('el slider de tono emite el tono pedido', (tester) async {
    Color? got;
    await tester.pumpWidget(host(const Color(0xFFFF0000), (c) => got = c));
    final rect = tester.getRect(find.byKey(const ValueKey('picker-hue')));
    // Un tercio del ancho = 120 grados (verde).
    await tester.tapAt(Offset(rect.left + rect.width / 3, rect.center.dy));
    expect(got, isNotNull);
    expect(colorToHsv(got!).hue, closeTo(120, 4));
  });

  testWidgets('expone etiquetas de accesibilidad', (tester) async {
    await tester.pumpWidget(host(const Color(0xFFFF0000), (_) {}));
    expect(find.bySemanticsLabel('Tono'), findsOneWidget);
    expect(find.bySemanticsLabel('Saturacion y brillo'), findsOneWidget);
  });

  testWidgets('un cambio externo de color se refleja sin emitir', (tester) async {
    var calls = 0;
    await tester.pumpWidget(host(const Color(0xFFFF0000), (_) => calls++));
    await tester.pumpWidget(host(const Color(0xFF0000FF), (_) => calls++));
    expect(calls, 0);
    expect(find.text('0, 0, 255'), findsOneWidget);
  });
}
