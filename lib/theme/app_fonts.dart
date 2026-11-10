import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Fuente de la interfaz. Se guarda por [name], así que renombrar un valor
/// perdería la elección de quien lo tenga.
enum AppFont {
  system(null, null),
  rounded('Nunito', 'assets/fonts/nunito/OFL.txt'),
  serif('Lora', 'assets/fonts/lora/OFL.txt'),
  mono('IBM Plex Mono', 'assets/fonts/ibm_plex_mono/OFL.txt');

  const AppFont(this.family, this.licenseAsset);

  /// Como en `pubspec.yaml`; `null` deja la fuente del sistema.
  final String? family;
  final String? licenseAsset;
}

/// Tamaño del texto elegido en la app. Se guarda por [name].
enum AppTextScale {
  small(0.85),
  normal(1.0),
  large(1.15),
  extraLarge(1.3);

  const AppTextScale(this.factor);

  final double factor;
}

AppFont parseAppFont(String? stored) =>
    AppFont.values.asNameMap()[stored] ?? AppFont.system;

AppTextScale parseAppTextScale(String? stored) =>
    AppTextScale.values.asNameMap()[stored] ?? AppTextScale.normal;

const double kMinTotalTextScale = 0.8;
const double kMaxTotalTextScale = 2.0;

/// Escala final de multiplicar la del sistema por la elegida en la app. Los
/// topes acotan lo que añade la app, nunca lo que ya pidió el sistema: al 100 %
/// devuelve [system] tal cual aunque esté fuera de ellos.
double combinedTextScale(double system, double user) {
  final lower = math.min(kMinTotalTextScale, system);
  final upper = math.max(kMaxTotalTextScale, system);
  return (system * user).clamp(lower, upper);
}

/// El modo cine ya pinta las letras a su máximo legible, por eso no se escala.
double lyricsLineFontSize(
  double base,
  AppTextScale scale, {
  required bool cinemaMode,
}) =>
    cinemaMode ? base : base * scale.factor;

/// Aplica el factor por tamaño de fuente: desde Android 14 el sistema agranda
/// menos el texto grande, y un factor único perdería esa curva.
class _UserTextScaler extends TextScaler {
  final TextScaler system;
  final double factor;

  const _UserTextScaler(this.system, this.factor);

  @override
  double scale(double fontSize) {
    if (fontSize == 0) return 0;
    return fontSize * combinedTextScale(system.scale(fontSize) / fontSize, factor);
  }

  @override
  double get textScaleFactor => scale(14) / 14;

  @override
  bool operator ==(Object other) =>
      other is _UserTextScaler && other.system == system && other.factor == factor;

  @override
  int get hashCode => Object.hash(system, factor);
}

/// Aplica [scale] al texto de [child]. El `MediaQuery` va siempre, también al
/// 100 %: si apareciera y desapareciera, cambiar el tamaño reharía todo lo que
/// hay debajo, navegador incluido.
class UserTextScale extends StatelessWidget {
  final AppTextScale scale;
  final Widget child;

  const UserTextScale({super.key, required this.scale, required this.child});

  @override
  Widget build(BuildContext context) {
    final data = MediaQuery.of(context);
    return MediaQuery(
      data: scale == AppTextScale.normal
          ? data
          : data.copyWith(textScaler: _UserTextScaler(data.textScaler, scale.factor)),
      child: child,
    );
  }
}

void registerFontLicenses() {
  LicenseRegistry.addLicense(() async* {
    for (final font in AppFont.values) {
      final asset = font.licenseAsset;
      if (asset == null) continue;
      yield LicenseEntryWithLineBreaks(
        [font.family!],
        await rootBundle.loadString(asset),
      );
    }
  });
}
