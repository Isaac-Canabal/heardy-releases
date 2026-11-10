import 'dart:convert';

import 'package:flutter/material.dart';

/// Zonas de la interfaz con color propio opcional. Se guardan por nombre, nunca
/// por índice: sumar una zona no necesita migración.
enum ColorArea { lyrics, nowPlayingTitle, playbackControls, navigation, miniPlayer }

/// WCAG para texto grande: las letras y el título miden 18 px o más.
const double minReadableContrast = 3.0;

const int _minOpaqueArgb = 0xFF000000;
const int _maxOpaqueArgb = 0xFFFFFFFF;

/// Lo guardado se ignora en silencio si no se entiende: una zona desconocida o
/// un color que no sea opaco vuelven a seguir el tema, sin afectar a las demás.
Map<ColorArea, Color> parseAreaColors(String? raw) {
  if (raw == null || raw.isEmpty) return {};
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return {};
  }
  if (decoded is! Map<String, dynamic>) return {};
  final colors = <ColorArea, Color>{};
  for (final area in ColorArea.values) {
    final value = decoded[area.name];
    if (value is int && value >= _minOpaqueArgb && value <= _maxOpaqueArgb) {
      colors[area] = Color(value);
    }
  }
  return colors;
}

String serializeAreaColors(Map<ColorArea, Color> colors) => jsonEncode({
      for (final entry in colors.entries) entry.key.name: entry.value.toARGB32(),
    });

/// Razón de contraste WCAG, de 1 a 21.
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// Blanco o negro, el que mejor se lea sobre [background].
Color readableOn(Color background) =>
    contrastRatio(Colors.white, background) >= contrastRatio(Colors.black, background)
        ? Colors.white
        : Colors.black;

/// Sube la luminosidad conservando el matiz hasta alcanzar [minContrast].
Color ensureReadableOnDark(
  Color color, {
  required Color background,
  double minContrast = 4.5,
}) {
  var hsl = HSLColor.fromColor(color);
  var out = color;
  while (contrastRatio(out, background) < minContrast && hsl.lightness < 1) {
    hsl = hsl.withLightness((hsl.lightness + 0.02).clamp(0.0, 1.0));
    out = hsl.toColor();
  }
  return out;
}

/// Sólo las zonas de texto avisan: un icono oscuro se sigue distinguiendo por
/// su forma, y el aviso es informativo, nunca impide elegir el color.
bool areaWantsContrastHint(
  ColorArea area,
  Color? override, {
  required Color background,
}) {
  if (override == null) return false;
  if (area != ColorArea.lyrics && area != ColorArea.nowPlayingTitle) return false;
  return contrastRatio(override, background) < minReadableContrast;
}

/// Una anulación explícita gana siempre, también frente al color dinámico de la
/// carátula: ese color sólo tiñe el fondo, nunca la zona que eligió el usuario.
Color resolveAreaColor(Color? override, Color fallback) => override ?? fallback;

class LyricsColors {
  final Color active;
  final Color inactive;
  final Color plain;
  final Color translation;

  const LyricsColors({
    required this.active,
    required this.inactive,
    required this.plain,
    required this.translation,
  });
}

LyricsColors resolveLyricsColors(Color? override) {
  final base = override ?? Colors.white;
  return LyricsColors(
    active: base,
    inactive: override?.withValues(alpha: 0.38) ?? Colors.white38,
    plain: override?.withValues(alpha: 0.7) ?? Colors.white70,
    translation: base.withValues(alpha: 0.4),
  );
}

class PlaybackControlColors {
  final Color icon;
  final Color secondaryIcon;
  final Color playButton;
  final Color playIcon;

  /// Barra de tiempo y estados activos (aleatorio, repetir).
  final Color accent;

  const PlaybackControlColors({
    required this.icon,
    required this.secondaryIcon,
    required this.playButton,
    required this.playIcon,
    required this.accent,
  });
}

PlaybackControlColors resolvePlaybackControlColors(
  Color? override, {
  required Color accent,
}) {
  if (override == null) {
    return PlaybackControlColors(
      icon: Colors.white,
      secondaryIcon: Colors.white70,
      playButton: Colors.white,
      playIcon: Colors.black,
      accent: accent,
    );
  }
  return PlaybackControlColors(
    icon: override,
    secondaryIcon: override.withValues(alpha: 0.7),
    playButton: override,
    playIcon: readableOn(override),
    accent: override,
  );
}

class MiniPlayerColors {
  final Color progress;

  /// `null` conserva el degradado principal del tema.
  final Color? playButton;
  final Color playIcon;

  const MiniPlayerColors({
    required this.progress,
    required this.playButton,
    required this.playIcon,
  });
}

MiniPlayerColors resolveMiniPlayerColors(
  Color? override, {
  required Color progress,
}) =>
    MiniPlayerColors(
      progress: override ?? progress,
      playButton: override,
      playIcon: override == null ? Colors.white : readableOn(override),
    );

/// La barra inferior toma el color del elemento seleccionado de su tema, no de
/// cada destino. `null` devuelve [base] tal cual.
NavigationBarThemeData navigationThemeWithOverride(
  NavigationBarThemeData base,
  Color? override,
) {
  if (override == null) return base;
  return base.copyWith(
    indicatorColor: override.withValues(alpha: 0.25),
    iconTheme: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.selected)
          ? IconThemeData(color: override, size: 24)
          : null,
    ),
    labelTextStyle: WidgetStateProperty.resolveWith((states) {
      final style = base.labelTextStyle?.resolve(states);
      if (!states.contains(WidgetState.selected)) return style;
      return (style ?? const TextStyle()).copyWith(color: override);
    }),
  );
}
