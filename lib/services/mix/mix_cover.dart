// Carátula de un mix de Heardy Mixer: las dos carátulas de origen fundidas a lo
// largo de la diagonal de arriba a la izquierda a abajo a la derecha, partidas
// por una línea ondulada con un trazo fino y claro. A ocupa el lado de arriba a
// la derecha y B el de abajo a la izquierda. Se dibuja una sola vez a un PNG
// pequeño en almacenamiento privado, como las demás carátulas.
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// Lado del PNG guardado, en píxeles.
const kMixCoverSize = 320;

/// Ondas completas a lo largo de la diagonal.
const kMixCoverWavePeriods = 3;

/// Altura de la onda respecto al lado: se ve como onda y no tapa ninguna mitad.
double mixCoverWaveAmplitude(double size) => size * 0.06;

/// Puntos de la onda, de (0, 0) a ([size], [size]) exactamente. El
/// desplazamiento es perpendicular a la diagonal (positivo hacia arriba a la
/// derecha) y se apaga hacia las esquinas con `sin(πt)`, así nunca sale del
/// cuadro. Puro y determinista: solo depende de [size].
List<Offset> mixCoverWave(double size, {int samples = 96}) {
  final amp = mixCoverWaveAmplitude(size);
  final points = <Offset>[];
  for (var i = 0; i <= samples; i++) {
    if (i == 0) {
      points.add(Offset.zero);
      continue;
    }
    if (i == samples) {
      points.add(Offset(size, size));
      continue;
    }
    final t = i / samples;
    final off = amp * math.sin(2 * math.pi * kMixCoverWavePeriods * t) * math.sin(math.pi * t);
    final d = off / math.sqrt2;
    points.add(Offset(t * size + d, t * size - d));
  }
  return points;
}

Path _side(List<Offset> wave, Offset corner) {
  final path = Path()..moveTo(wave.first.dx, wave.first.dy);
  for (final p in wave.skip(1)) {
    path.lineTo(p.dx, p.dy);
  }
  return path
    ..lineTo(corner.dx, corner.dy)
    ..close();
}

void _paintHalf(Canvas canvas, Path clip, Rect square, ui.Image? image, Gradient fallback) {
  canvas.save();
  canvas.clipPath(clip);
  if (image == null) {
    canvas.drawRect(square, Paint()..shader = fallback.createShader(square));
  } else {
    // Recorte central a cuadrado, como `BoxFit.cover`.
    final w = image.width.toDouble(), h = image.height.toDouble();
    final side = math.min(w, h);
    final src = Rect.fromLTWH((w - side) / 2, (h - side) / 2, side, side);
    canvas.drawImageRect(image, src, square, Paint()..filterQuality = FilterQuality.medium);
  }
  canvas.restore();
}

/// Compone la carátula. Una imagen `null` cae al degradado de su mitad.
Future<ui.Image> composeMixCover({
  required ui.Image? a,
  required ui.Image? b,
  required Gradient fallbackA,
  required Gradient fallbackB,
  int size = kMixCoverSize,
}) {
  final s = size.toDouble();
  final square = Rect.fromLTWH(0, 0, s, s);
  final wave = mixCoverWave(s);
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, square);
  _paintHalf(canvas, _side(wave, Offset(s, 0)), square, a, fallbackA);
  _paintHalf(canvas, _side(wave, Offset(0, s)), square, b, fallbackB);
  final stroke = Path()..moveTo(0, 0);
  for (final p in wave.skip(1)) {
    stroke.lineTo(p.dx, p.dy);
  }
  canvas.drawPath(
    stroke,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.5, s * 0.012)
      ..strokeJoin = StrokeJoin.round
      ..color = const Color(0xE6FFFFFF),
  );
  return recorder.endRecording().toImage(size, size);
}

Future<Uint8List> encodeMixCoverPng(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  if (data == null) throw StateError('no se pudo codificar la carátula');
  return data.buffer.asUint8List();
}

/// `null` si los bytes no son una imagen que se pueda leer.
Future<ui.Image?> _decode(Uint8List? bytes, int size) async {
  if (bytes == null || bytes.isEmpty) return null;
  try {
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: size);
    return (await codec.getNextFrame()).image;
  } catch (e) {
    print('Mix: una carátula de origen no se pudo leer (${e.runtimeType})');
    return null;
  }
}

/// Dibuja la carátula del mix [id] y la guarda con [save] como `mix_<id>`.
/// Devuelve su ruta, o '' (degradado del tema) si no se pudo guardar.
Future<String> renderMixCoverFile({
  required String id,
  required Uint8List? coverA,
  required Uint8List? coverB,
  required Gradient fallbackA,
  required Gradient fallbackB,
  required Future<String> Function(String id, Uint8List bytes) save,
  int size = kMixCoverSize,
}) async {
  final image = await composeMixCover(
    a: await _decode(coverA, size),
    b: await _decode(coverB, size),
    fallbackA: fallbackA,
    fallbackB: fallbackB,
    size: size,
  );
  final png = await encodeMixCoverPng(image);
  image.dispose();
  return save('mix_$id', png);
}
