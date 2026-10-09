// Verifica, a nivel de PÍXELES renderizados, que una carátula se recorta
// centrada y nunca aparece con franjas a los lados.
//
// El bug que cubre: `SmartAlbumArt` fijaba `cacheWidth` Y `cacheHeight` a la
// vez, y `instantiateImageCodec` con las dos dimensiones redimensiona a
// exactamente ese tamaño **ignorando la relación de aspecto**. Una miniatura
// 16:9 quedaba aplastada a un cuadrado, `BoxFit.cover` se quedaba sin nada
// que recortar, y las franjas negras que traen incrustadas muchas miniaturas
// de YouTube (carátula cuadrada centrada sobre lienzo 16:9) se veían como
// barras a los lados — sólo en la pantalla del reproductor, porque es el
// único sitio que limitaba el decode.
//
// Un test que sólo mirara el código fuente no probaría nada sobre el
// resultado visible; éste dibuja una miniatura 16:9 sintética (franjas
// negras + cuadrado rojo centrado) y comprueba que lo que se pinta en el
// cuadro es TODO rojo.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heardy/screens/now_playing_screen.dart' show SmartAlbumArt;

const _barColor = Color(0xFF000000); // las franjas incrustadas
const _artColor = Color(0xFFFF0000); // la carátula real, centrada

/// Una miniatura 16:9 con un cuadrado de carátula centrado y franjas negras
/// a ambos lados — la forma exacta de un thumbnail de "Art Track" de YouTube.
///
/// **640×360 y no algo pequeño, a propósito.** `Image.file` no amplía nunca
/// (`ResizeImage(allowUpscaling: false)`), así que con una miniatura más
/// chica que el tamaño de decodificación el redimensionado se salta entero y
/// el bug no se reproduce — este test daba un falso verde con una imagen de
/// 160×90. Tiene que ser mayor que `size × devicePixelRatio` para que el
/// decoder haga el trabajo que se está verificando.
Future<File> _write16x9Thumbnail(Directory dir) async {
  const w = 640.0, h = 360.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(const Rect.fromLTWH(0, 0, w, h), Paint()..color = _barColor);
  canvas.drawRect(const Rect.fromLTWH((w - h) / 2, 0, h, h), Paint()..color = _artColor);
  final image = await recorder.endRecording().toImage(w.round(), h.round());
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File('${dir.path}/art_16x9.png');
  await file.writeAsBytes(data!.buffer.asUint8List(), flush: true);
  return file;
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('heardy_art_');
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  testWidgets('una miniatura 16:9 se recorta centrada, sin franjas a los lados', (tester) async {
    const size = 90.0;
    final key = GlobalKey();
    late ByteData pixels;

    await tester.runAsync(() async {
      final art = await _write16x9Thumbnail(tempDir);

      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: RepaintBoundary(
              key: key,
              child: SmartAlbumArt(artPath: art.path, title: 'Canción', size: size),
            ),
          ),
        ),
      );

      // `Image.file` decodifica de forma asíncrona: hace falta tiempo de
      // reloj real (no sólo `pump`) antes de que haya algo que capturar.
      await Future.delayed(const Duration(milliseconds: 300));
      await tester.pump();
      await tester.pump();

      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final captured = await boundary.toImage(pixelRatio: 1);
      pixels = (await captured.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    });

    int red(int x, int y) => pixels.getUint8(((y * size.round()) + x) * 4);
    int green(int x, int y) => pixels.getUint8((((y * size.round()) + x) * 4) + 1);

    // Los bordes izquierdo y derecho, a media altura: si el recorte es
    // correcto son parte de la carátula (rojo). Si la imagen se aplastó, son
    // las franjas negras incrustadas.
    for (final x in [1, 4, size.round() - 5, size.round() - 2]) {
      expect(
        red(x, size ~/ 2) > 200 && green(x, size ~/ 2) < 60,
        isTrue,
        reason: 'el píxel x=$x salió oscuro: la carátula se está mostrando con franjas '
            '(aspecto aplastado) en vez de recortada al centro',
      );
    }
  });
}
