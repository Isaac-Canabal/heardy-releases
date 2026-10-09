// Cubre MaxWidthCenter: el arreglo real del bug de W3 (plan de escritorio)
// reportado contra el `.exe` instalado — `Center(child: ConstrainedBox(...))`
// afloja las restricciones en los dos ejes, no sólo el ancho, así que el
// contenido de cada pantalla colapsaba a altura cero y sólo quedaba visible
// la barra de navegación inferior (que tiene su propia altura fija).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heardy/widgets/max_width_center.dart';

void main() {
  // El tamaño de la superficie de prueba es 800x600 por defecto — hay que
  // cambiarlo de verdad en el binding, no sólo envolver en un `SizedBox`:
  // un `SizedBox` en la raíz igual queda acotado por las restricciones
  // tensas que ya vienen del binding.
  Future<void> setSurfaceSize(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Widget probe({bool stretchHeight = true}) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: MaxWidthCenter(
        stretchHeight: stretchHeight,
        // Un `Container` sin tamaño propio: si las restricciones de altura
        // se aflojaran (el bug original), esto se reduciría a altura cero
        // en vez de llenar el alto disponible.
        child: Container(key: const Key('probe'), color: Colors.black),
      ),
    );
  }

  testWidgets('en una ventana ancha, el hijo llena el alto disponible y el ancho se limita a 480', (
    tester,
  ) async {
    await setSurfaceSize(tester, const Size(1280, 720));
    await tester.pumpWidget(probe());

    final size = tester.getSize(find.byKey(const Key('probe')));
    expect(size.height, 720, reason: 'la altura NO debe colapsar — este es el bug real reportado');
    expect(size.width, 480);
  });

  testWidgets('en una pantalla de teléfono (más angosta que el máximo), es un no-op', (
    tester,
  ) async {
    await setSurfaceSize(tester, const Size(360, 800));
    await tester.pumpWidget(probe());

    final size = tester.getSize(find.byKey(const Key('probe')));
    expect(size.height, 800);
    expect(size.width, 360);
  });

  testWidgets(
    'dentro de un Scaffold real, stretchHeight:false no le roba altura al body '
    '(regresión real: Align sin heightFactor se expandía a toda la ventana)',
    (tester) async {
      // Este es el bug de verdad, reproducido tal cual estaba en producción:
      // `Align` sin `heightFactor` toma TODA la altura disponible aunque su
      // hijo (la barra de navegación) tenga una altura fija — así que
      // `Scaffold`, al medir cuánto necesita `bottomNavigationBar`, recibía
      // ~toda la ventana y le dejaba al `body` una altura de 0. El test
      // anterior (que sólo medía el hijo más interno) no lo detectaba,
      // porque el hijo sí conservaba su tamaño — lo que mentía era el
      // tamaño que `MaxWidthCenter` reportaba hacia SU PROPIO padre.
      await setSurfaceSize(tester, const Size(1280, 720));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Container(key: const Key('body'), color: Colors.blue),
            bottomNavigationBar: MaxWidthCenter(
              stretchHeight: false,
              child: SizedBox(
                key: const Key('navbar'),
                height: 68,
                child: Container(color: Colors.black),
              ),
            ),
          ),
        ),
      );

      final maxWidthCenterSize = tester.getSize(find.byType(MaxWidthCenter));
      expect(
        maxWidthCenterSize.height,
        68,
        reason: 'MaxWidthCenter debe reportarle a Scaffold la altura real del hijo, no llenar la ventana',
      );

      final bodySize = tester.getSize(find.byKey(const Key('body')));
      expect(
        bodySize.height,
        720 - 68,
        reason: 'el body debe recibir el resto de la altura de la ventana, no colapsar a 0',
      );
    },
  );
}
