import 'dart:math' as math;

import 'package:flutter/widgets.dart';

// Los nombres de estos enums se guardan en preferencias: renombrar uno devuelve
// esa opción a su valor predeterminado.

enum NowPlayingTitleAlign {
  left(TextAlign.left, CrossAxisAlignment.start, Alignment.centerLeft),
  center(TextAlign.center, CrossAxisAlignment.center, Alignment.center),
  right(TextAlign.right, CrossAxisAlignment.end, Alignment.centerRight);

  const NowPlayingTitleAlign(this.textAlign, this.crossAxis, this.alignment);

  final TextAlign textAlign;

  /// `textAlign` no basta: la `Column` de la pantalla encoge un título corto
  /// al ancho de su texto.
  final CrossAxisAlignment crossAxis;
  final Alignment alignment;
}

enum NowPlayingArtSize { small, medium, large }

/// Bloques de la pantalla de reproducción, en su orden predeterminado.
enum NowPlayingBlock { art, info, actions, seekBar, controls }

enum DesktopPanelSide { right, left }

const double kSmallArtFactor = 0.7;

/// Cabe de sobra en un teléfono; sólo limita pantallas muy altas y anchas.
const double kPhoneArtMaxLarge = 400;

/// Alto que necesitan los otros cuatro bloques, márgenes de la carátula
/// incluidos, con el texto de la app al 130 %.
const double kPhoneArtReservedHeight = 320;

/// Cabecera, título, controles y pestañas del panel, y un mínimo de letra.
const double kDesktopPanelArtReservedHeight = 360;

/// Lo guardado puede venir de otra versión o estar corrupto.
T parseStoredEnum<T extends Enum>(Object? stored, List<T> values, T fallback) =>
    stored is String ? values.asNameMap()[stored] ?? fallback : fallback;

bool parseStoredBool(Object? stored, {required bool fallback}) => stored is bool ? stored : fallback;

/// Tamaño de la carátula en la pantalla de reproducción. La mediana está
/// limitada al menor entre el máximo original y lo que entra: fija a 300 px
/// desbordaba a lo ancho en Android de 360 dp (300 + 64 de padding) y a lo alto
/// en pantallas bajas, donde la `Column` con `spaceEvenly` no tenía margen.
double phoneArtSize(
  NowPlayingArtSize size, {
  required double maxWidth,
  required double maxHeight,
  double textScale = 1,
}) {
  return _resizedArt(
    size,
    medium: math.min(300.0, math.min(maxWidth - 64, maxHeight * 0.38)),
    largeLimit: math.min(
      kPhoneArtMaxLarge,
      math.min(maxWidth - 64, maxHeight - _reserved(kPhoneArtReservedHeight, textScale)),
    ),
  );
}

/// Carátula del panel de escritorio; la letra expandida usa su propio tamaño.
double desktopPanelArtSize(
  NowPlayingArtSize size, {
  required double maxWidth,
  required double maxHeight,
  double textScale = 1,
}) {
  return _resizedArt(
    size,
    medium: math.min(maxWidth - 56, maxHeight * 0.34),
    largeLimit: math.min(maxWidth - 56, maxHeight - _reserved(kDesktopPanelArtReservedHeight, textScale)),
  );
}

/// Un texto menor que el normal no ajusta el margen: es sólo un tope prudente.
double _reserved(double height, double textScale) => height * math.max(1, textScale);

/// Grande nunca baja de [medium]: donde no queda sitio, colapsa igual que ella.
double _resizedArt(NowPlayingArtSize size, {required double medium, required double largeLimit}) => switch (size) {
      NowPlayingArtSize.small => medium * kSmallArtFactor,
      NowPlayingArtSize.medium => medium,
      NowPlayingArtSize.large => math.max(medium, largeLimit),
    };

/// Contenido y panel de la fila del escritorio, cada uno en su lado.
List<T> arrangeDesktopColumns<T>(
  DesktopPanelSide side, {
  required T content,
  required T divider,
  T? panel,
}) {
  if (panel == null) return [content];
  return side == DesktopPanelSide.left ? [panel, divider, content] : [content, divider, panel];
}
