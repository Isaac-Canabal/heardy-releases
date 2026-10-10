import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart' show HSLColor;

const double minAccentContrast = 4.5;
const double minAccentLightness = 0.2;
const int _coverSampleWidth = 48;
const int _cacheLimit = 64;

double contrastWithWhite(ui.Color c) => 1.05 / (c.computeLuminance() + 0.05);

/// Mantiene el matiz y baja la luminosidad hasta que el texto blanco encima
/// siga siendo legible; sube un casi negro para que el fondo no desaparezca.
ui.Color clampAccent(ui.Color color) {
  final hsl = HSLColor.fromColor(color);
  var l = hsl.lightness;
  if (l >= minAccentLightness && contrastWithWhite(color) >= minAccentContrast) return color;
  if (l < minAccentLightness) l = minAccentLightness;
  var out = hsl.withLightness(l).toColor();
  while (contrastWithWhite(out) < minAccentContrast && l > minAccentLightness) {
    l = (l - 0.01).clamp(minAccentLightness, 1.0);
    out = hsl.withLightness(l).toColor();
  }
  return out;
}

/// Color de acento de una imagen RGBA (miniatura): agrupa los píxeles en
/// cubetas de 4 bits por canal, descarta casi negro/casi blanco/transparente
/// y favorece los colores saturados sobre el gris que abunde. `null` si no
/// queda ningún píxel utilizable.
ui.Color? accentFromRgba(Uint8List rgba) {
  final score = <int, double>{};
  final sums = <int, List<double>>{};
  for (var i = 0; i + 3 < rgba.length; i += 4) {
    if (rgba[i + 3] < 128) continue;
    final r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
    final maxC = r > g ? (r > b ? r : b) : (g > b ? g : b);
    final minC = r < g ? (r < b ? r : b) : (g < b ? g : b);
    final lightness = (maxC + minC) / 510.0;
    if (lightness < 0.1 || lightness > 0.92) continue;
    final denom = 1 - (2 * lightness - 1).abs();
    final saturation = denom == 0 ? 0.0 : (maxC - minC) / 255.0 / denom;
    final key = ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4);
    score[key] = (score[key] ?? 0) + 1 + 3 * saturation.clamp(0.0, 1.0);
    final s = sums.putIfAbsent(key, () => [0, 0, 0, 0]);
    s[0] += r;
    s[1] += g;
    s[2] += b;
    s[3] += 1;
  }
  if (score.isEmpty) return null;
  final best = score.entries.reduce((a, b) => b.value > a.value ? b : a).key;
  final s = sums[best]!;
  final avg = ui.Color.fromARGB(
    255,
    (s[0] / s[3]).round(),
    (s[1] / s[3]).round(),
    (s[2] / s[3]).round(),
  );
  return clampAccent(avg);
}

final Map<String, ui.Color> _accentCache = {};

/// Acento de la carátula guardada en [artPath]; `null` sin archivo o si no se
/// pudo decodificar (el llamador cae al color del tema). Cacheado por ruta.
Future<ui.Color?> coverAccentColor(String artPath) async {
  if (artPath.isEmpty) return null;
  final cached = _accentCache[artPath];
  if (cached != null) return cached;
  try {
    final file = File(artPath);
    if (!file.existsSync()) return null;
    final codec = await ui.instantiateImageCodec(
      await file.readAsBytes(),
      targetWidth: _coverSampleWidth,
    );
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
    frame.image.dispose();
    codec.dispose();
    if (data == null) return null;
    final color = accentFromRgba(data.buffer.asUint8List());
    if (color == null) return null;
    if (_accentCache.length >= _cacheLimit) _accentCache.remove(_accentCache.keys.first);
    return _accentCache[artPath] = color;
  } catch (e) {
    print('Color de carátula: no se pudo extraer (${e.runtimeType})');
    return null;
  }
}
