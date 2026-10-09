// Cubre la lógica pura del diseño de escritorio (W3 del plan de escritorio):
// el corte por ancho, el reparto de columnas con el panel de "reproduciendo
// ahora" abierto/cerrado, y el volumen (normalización + pasos de teclado).
// El shell en sí lee el `AudioPlayerHandler` real y no tiene doble de test.
import 'package:flutter_test/flutter_test.dart';

import 'package:heardy/services/audio_player_handler.dart';
import 'package:heardy/services/desktop_layout.dart';

void main() {
  group('isDesktopLayout', () {
    test('un teléfono nunca entra en el diseño de escritorio', () {
      expect(isDesktopLayout(360), isFalse);
      expect(isDesktopLayout(430), isFalse);
      expect(isDesktopLayout(899), isFalse);
    });

    test('a partir del corte sí', () {
      expect(isDesktopLayout(900), isTrue);
      expect(isDesktopLayout(1280), isTrue);
    });
  });

  group('desktopLayoutFor', () {
    test('con el panel cerrado el contenido se queda con todo el resto', () {
      final spec = desktopLayoutFor(width: 1280, panelOpen: false);
      expect(spec.panelWidth, 0);
      expect(spec.sidebarWidth, desktopSidebarWidth);
      expect(spec.contentWidth, 1280 - desktopSidebarWidth);
    });

    test('con el panel abierto ocupa un tercio de la ventana', () {
      final spec = desktopLayoutFor(width: 1280, panelOpen: true);
      expect(spec.panelWidth, closeTo(1280 / 3, 0.01));
      expect(
        spec.sidebarWidth + spec.contentWidth + spec.panelWidth,
        closeTo(1280, 0.01),
      );
    });

    test('el panel no baja del mínimo en una ventana al límite', () {
      final spec = desktopLayoutFor(width: 900, panelOpen: true);
      expect(spec.panelWidth, minPanelWidth);
      expect(spec.contentWidth, 900 - desktopSidebarWidth - minPanelWidth);
    });

    test('ni pasa del máximo en una ventana enorme', () {
      final spec = desktopLayoutFor(width: 2560, panelOpen: true);
      expect(spec.panelWidth, maxPanelWidth);
    });

    test('en 1000x700 el contenido conserva un ancho usable', () {
      final spec = desktopLayoutFor(width: 1000, panelOpen: true);
      expect(spec.contentWidth, greaterThanOrEqualTo(360));
    });
  });

  group('clampVolume', () {
    test('acota a [0, 1]', () {
      expect(clampVolume(-0.5), 0.0);
      expect(clampVolume(1.7), 1.0);
      expect(clampVolume(0.42), 0.42);
    });

    test('un valor no finito vuelve al máximo, nunca deja la app muda', () {
      expect(clampVolume(double.nan), 1.0);
      expect(clampVolume(double.infinity), 1.0);
    });
  });

  group('steppedVolume', () {
    test('sube y baja de a un paso, sin basura de coma flotante', () {
      expect(steppedVolume(0.1, up: true), 0.15);
      expect(steppedVolume(0.15, up: false), 0.1);
    });

    test('se detiene en los extremos', () {
      expect(steppedVolume(1.0, up: true), 1.0);
      expect(steppedVolume(0.02, up: false), 0.0);
    });
  });
}
