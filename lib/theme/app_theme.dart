import 'package:flutter/material.dart';
import '../providers/settings_provider.dart';

/// Visual design system for Heardy.
abstract final class AppTheme {
  static AppThemePreset activePreset = AppThemePreset.navy;

  // Sólo relevantes cuando activePreset == custom — ver applyCustomColors.
  static Color customPrimary = const Color(0xFF2563EB);
  static Color customSecondary = const Color(0xFF38BDF8);
  static bool customCombined = true;

  static _Palette get _p => activePreset == AppThemePreset.custom
      ? _customPalette(customPrimary, customSecondary, customCombined)
      : _palettes[activePreset]!;

  static Color get primary => _p.primary;
  static Color get primaryLight => _p.primaryLight;
  static Color get accent => _p.accent;
  static Color get accentPink => _p.accentPink;
  static Color get surface => _p.surface;
  static Color get surfaceLight => _p.surfaceLight;
  static Color get backgroundTop => _p.backgroundTop;
  static Color get backgroundBottom => _p.backgroundBottom;

  static LinearGradient get backgroundGradient => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [_p.backgroundTop, _p.backgroundMid, _p.backgroundBottom],
      );

  static LinearGradient get primaryGradient => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: _p.primaryGradient,
      );

  static LinearGradient get accentGradient => LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [_p.accentPink, _p.primary, _p.accent],
      );

  static const progressGradient = LinearGradient(
    colors: [Color(0xFF06B6D4), Color(0xFF60A5FA), Color(0xFF818CF8)],
  );

  static const _placeholderGradients = <List<Color>>[
    [Color(0xFF6366F1), Color(0xFFA855F7)],
    [Color(0xFFEC4899), Color(0xFFF97316)],
    [Color(0xFF0EA5E9), Color(0xFF22D3EE)],
    [Color(0xFF10B981), Color(0xFF84CC16)],
    [Color(0xFFF59E0B), Color(0xFFEF4444)],
    [Color(0xFF8B5CF6), Color(0xFFD946EF)],
  ];

  /// Deterministic placeholder gradient for a song with no cover art — the
  /// same title always maps to the same colors (D5), so a library without
  /// artwork doesn't render as a wall of identical tiles.
  static LinearGradient gradientForTitle(String title) {
    final index = title.hashCode.abs() % _placeholderGradients.length;
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: _placeholderGradients[index],
    );
  }

  static BoxShadow get cardGlow => BoxShadow(
        color: _p.primary.withValues(alpha: 0.35),
        blurRadius: 20,
        offset: const Offset(0, 8),
      );

  static ThemeData dark() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: backgroundTop,
      colorScheme: ColorScheme.dark(
        primary: primary,
        secondary: accent,
        surface: surface,
        onPrimary: Colors.white,
        onSurface: Colors.white,
      ),
      appBarTheme: const AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        foregroundColor: Colors.white,
        backgroundColor: Colors.transparent,
        titleTextStyle: TextStyle(
          color: Colors.white,
          fontSize: 22,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.3,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface.withValues(alpha: 0.95),
        indicatorColor: primary.withValues(alpha: 0.25),
        labelTextStyle: WidgetStateProperty.all(
          const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: primary, width: 1.5),
        ),
        hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.35)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        backgroundColor: surfaceLight,
        contentTextStyle: const TextStyle(color: Colors.white),
        actionTextColor: primaryLight,
      ),
      textTheme: const TextTheme(
        bodyLarge: TextStyle(color: Colors.white),
        bodyMedium: TextStyle(color: Color(0xFF94A3B8)),
      ),
    );
  }

  static void applyPreset(AppThemePreset preset) {
    activePreset = preset;
  }

  /// Sincroniza los colores del modo "Personalizado". Se llama siempre desde
  /// `HeardyApp.build` junto a [applyPreset], sin condicionar — no hace nada
  /// visible salvo que `activePreset` sea `custom`, así que no hay riesgo de
  /// pisar un preset fijo por error de orden.
  static void applyCustomColors({
    required Color primary,
    required Color secondary,
    required bool combined,
  }) {
    customPrimary = primary;
    customSecondary = secondary;
    customCombined = combined;
  }

  /// Los dos colores representativos de [preset], para dibujar un swatch de
  /// vista previa (selector de tema) sin duplicar la paleta completa.
  static List<Color> previewColors(AppThemePreset preset) {
    if (preset == AppThemePreset.custom) {
      return [customPrimary, customSecondary];
    }
    final palette = _palettes[preset]!;
    return [palette.primary, palette.primaryGradient.last];
  }

  /// Deriva una paleta completa a partir de los dos colores que eligió el
  /// usuario. El fondo/superficie siempre sale de acá (nunca de los colores
  /// elegidos directamente) — así "nunca 100% negro" es una propiedad de la
  /// función, no algo que dependa de qué haya elegido el usuario: se satura
  /// muy poco y se limita la luminosidad a un mínimo de 0.03, nunca 0.
  ///
  /// [combined] decide si el degradado principal (`primaryGradient`, el más
  /// visible: botones, glow de cards resaltadas) mezcla ambos colores o usa
  /// sólo tonos del principal — el secundario sigue usándose igual como
  /// `accent`/`accentPink` en los dos casos, lo que cambia es si además se
  /// funde con el principal en un degradado.
  static _Palette _customPalette(Color primary, Color secondary, bool combined) {
    final hsl = HSLColor.fromColor(primary);
    Color shade(double lightness, {double saturationFactor = 0.4}) {
      return HSLColor.fromColor(primary)
          .withLightness(lightness.clamp(0.03, 1.0))
          .withSaturation((hsl.saturation * saturationFactor).clamp(0.0, 1.0))
          .toColor();
    }

    final primaryLight =
        hsl.withLightness((hsl.lightness + 0.18).clamp(0.0, 1.0)).toColor();
    final gradientColors = combined
        ? [primary, Color.lerp(primary, secondary, 0.5)!, secondary]
        : [
            primary,
            hsl.withLightness((hsl.lightness * 0.78).clamp(0.05, 1.0)).toColor(),
            hsl.withLightness((hsl.lightness * 0.58).clamp(0.05, 1.0)).toColor(),
          ];

    return _Palette(
      primary: primary,
      primaryLight: primaryLight,
      accent: secondary,
      accentPink: secondary,
      surface: shade(0.09),
      surfaceLight: shade(0.13),
      backgroundTop: shade(0.035),
      backgroundMid: shade(0.05),
      backgroundBottom: shade(0.065),
      primaryGradient: gradientColors,
    );
  }

  static BoxDecoration gradientScaffold() => BoxDecoration(
        gradient: backgroundGradient,
      );

  static BoxDecoration glassCard({bool highlighted = false}) => BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: surface.withValues(alpha: 0.72),
        border: Border.all(
          color: highlighted
              ? primary.withValues(alpha: 0.55)
              : Colors.white.withValues(alpha: 0.07),
          width: highlighted ? 1.5 : 1,
        ),
        boxShadow: highlighted ? [cardGlow] : const [],
      );

  static BoxDecoration playlistCard() => BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: surfaceLight.withValues(alpha: 0.65),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      );

  static Widget gradientButton({
    required VoidCallback? onPressed,
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.symmetric(vertical: 16),
  }) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: onPressed != null ? primaryGradient : null,
        color: onPressed == null ? Colors.grey.shade800 : null,
        borderRadius: BorderRadius.circular(14),
        boxShadow: onPressed != null
            ? [
                BoxShadow(
                  color: primary.withValues(alpha: 0.4),
                  blurRadius: 14,
                  offset: const Offset(0, 5),
                ),
              ]
            : null,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(14),
          child: Padding(padding: padding, child: Center(child: child)),
        ),
      ),
    );
  }

  static String formatDuration(int totalSeconds) {
    if (totalSeconds <= 0) return '0 min';
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    if (h > 0) return '${h}h ${m}m';
    return '${m} min';
  }

  static final _palettes = {
    AppThemePreset.navy: _Palette(
      primary: Color(0xFF2563EB),
      primaryLight: Color(0xFF60A5FA),
      accent: Color(0xFF38BDF8),
      accentPink: Color(0xFF6366F1),
      surface: Color(0xFF0F1729),
      surfaceLight: Color(0xFF152038),
      backgroundTop: Color(0xFF050A18),
      backgroundMid: Color(0xFF0A1228),
      backgroundBottom: Color(0xFF0D1630),
      primaryGradient: [
        Color(0xFF2563EB),
        Color(0xFF1D4ED8),
        Color(0xFF1E40AF),
      ],
    ),
    AppThemePreset.violet: _Palette(
      primary: Color(0xFF7C3AED),
      primaryLight: Color(0xFFA78BFA),
      accent: Color(0xFF06B6D4),
      accentPink: Color(0xFFEC4899),
      surface: Color(0xFF1A1630),
      surfaceLight: Color(0xFF252042),
      backgroundTop: Color(0xFF0B0A14),
      backgroundMid: Color(0xFF120E24),
      backgroundBottom: Color(0xFF15102A),
      primaryGradient: [
        Color(0xFF7C3AED),
        Color(0xFF4F46E5),
        Color(0xFF2563EB),
      ],
    ),
    AppThemePreset.rose: _Palette(
      primary: Color(0xFFDB2777),
      primaryLight: Color(0xFFF472B6),
      accent: Color(0xFFFB7185),
      accentPink: Color(0xFFF43F5E),
      surface: Color(0xFF1F1018),
      surfaceLight: Color(0xFF2A1520),
      backgroundTop: Color(0xFF120810),
      backgroundMid: Color(0xFF1A0C14),
      backgroundBottom: Color(0xFF220F1A),
      primaryGradient: [
        Color(0xFFDB2777),
        Color(0xFFBE185D),
        Color(0xFF9D174D),
      ],
    ),
    // Los tres presets de abajo (verde/naranja/rojo) siguen el mismo patrón
    // que navy/violet/rose: fondo/superficie casi negros pero teñidos del
    // matiz principal — nunca #000000 literal.
    AppThemePreset.green: _Palette(
      primary: Color(0xFF16A34A),
      primaryLight: Color(0xFF4ADE80),
      accent: Color(0xFF84CC16),
      accentPink: Color(0xFFEAB308),
      surface: Color(0xFF0F1F16),
      surfaceLight: Color(0xFF16291D),
      backgroundTop: Color(0xFF050D08),
      backgroundMid: Color(0xFF081408),
      backgroundBottom: Color(0xFF0A1810),
      primaryGradient: [
        Color(0xFF16A34A),
        Color(0xFF15803D),
        Color(0xFF166534),
      ],
    ),
    AppThemePreset.orange: _Palette(
      primary: Color(0xFFEA580C),
      primaryLight: Color(0xFFFB923C),
      accent: Color(0xFFF59E0B),
      accentPink: Color(0xFFDC2626),
      surface: Color(0xFF1F1206),
      surfaceLight: Color(0xFF2A1908),
      backgroundTop: Color(0xFF120A03),
      backgroundMid: Color(0xFF1A0F05),
      backgroundBottom: Color(0xFF1F1206),
      primaryGradient: [
        Color(0xFFEA580C),
        Color(0xFFC2410C),
        Color(0xFF9A3412),
      ],
    ),
    AppThemePreset.red: _Palette(
      primary: Color(0xFFDC2626),
      primaryLight: Color(0xFFF87171),
      accent: Color(0xFFF97316),
      accentPink: Color(0xFFF43F5E),
      surface: Color(0xFF1F0A0A),
      surfaceLight: Color(0xFF2A1010),
      backgroundTop: Color(0xFF120505),
      backgroundMid: Color(0xFF1A0808),
      backgroundBottom: Color(0xFF1F0A0A),
      primaryGradient: [
        Color(0xFFDC2626),
        Color(0xFFB91C1C),
        Color(0xFF991B1B),
      ],
    ),
  };
}

class _Palette {
  final Color primary;
  final Color primaryLight;
  final Color accent;
  final Color accentPink;
  final Color surface;
  final Color surfaceLight;
  final Color backgroundTop;
  final Color backgroundMid;
  final Color backgroundBottom;
  final List<Color> primaryGradient;

  const _Palette({
    required this.primary,
    required this.primaryLight,
    required this.accent,
    required this.accentPink,
    required this.surface,
    required this.surfaceLight,
    required this.backgroundTop,
    required this.backgroundMid,
    required this.backgroundBottom,
    required this.primaryGradient,
  });
}
