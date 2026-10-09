// Verifica que la tarjeta de compartir se pueda CAPTURAR de verdad, que la
// captura no sea transparente, y que incluya todo el contenido.
//
// Estos tres son exactamente los modos de fallo que se dieron en el
// dispositivo y que ningún test cubría:
//
// 1. `renderBoundaryPng` devolvía `null` (el botón "no hacía nada").
// 2. La imagen salía sobre transparencia — `AppTheme.glassCard()` es
//    translúcido, así que la tarjeta tiene que poner su propio fondo opaco.
// 3. El contenido se cortaba: con la lista de artistas llena, la sección de
//    canciones quedaba fuera de la tarjeta de alto fijo.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heardy/l10n/app_localizations.dart';
import 'package:heardy/models/statistics_data.dart';
import 'package:heardy/services/share_image_service.dart';
import 'package:heardy/widgets/share_stats_card.dart';

StatisticsData _data({int songs = 10, int artists = 10}) {
  return StatisticsData(
    totalPlays: 123,
    totalListenSeconds: 7325,
    topArtists: List.generate(
      artists,
      (i) => TopArtistStat(name: 'Artista $i', playCount: artists - i),
    ),
    topSongs: List.generate(
      songs,
      (i) => TopSongStat(
        songId: 's$i',
        title: 'Canción $i',
        artist: 'Artista $i',
        artPath: '',
        playCount: songs - i,
      ),
    ),
  );
}

/// Monta la tarjeta con el MISMO envoltorio que usa la hoja de compartir
/// (`FittedBox` con alto acotado), que es lo que garantiza que la tarjeta se
/// pinte entera aunque sea más alta que la pantalla.
Future<GlobalKey> _pumpCard(WidgetTester tester, StatisticsData data) async {
  final key = GlobalKey();
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Center(
          child: SizedBox(
            height: 420,
            child: FittedBox(
              fit: BoxFit.contain,
              child: RepaintBoundary(
                key: key,
                child: ShareStatsCard(username: 'isaac', data: data, isWeek: true),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return key;
}

void main() {
  testWidgets('la tarjeta se captura y devuelve bytes PNG', (tester) async {
    final key = await _pumpCard(tester, _data());

    Uint8List? bytes;
    await tester.runAsync(() async {
      bytes = await renderBoundaryPng(key, pixelRatio: 2);
    });

    expect(bytes, isNotNull, reason: 'renderBoundaryPng devolvió null: el botón "no haría nada"');
    expect(bytes!.length, greaterThan(1000));
    // Cabecera PNG.
    expect(bytes!.sublist(1, 4), equals([0x50, 0x4E, 0x47]));
  });

  testWidgets('el píxel (0,0) es OPACO — nunca se exporta sobre transparencia', (tester) async {
    final key = await _pumpCard(tester, _data());

    late ByteData pixels;
    await tester.runAsync(() async {
      final bytes = await renderBoundaryPng(key, pixelRatio: 1);
      final codec = await ui.instantiateImageCodec(bytes!);
      final frame = await codec.getNextFrame();
      pixels = (await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    });

    // El cuarto byte del primer píxel es su alfa. 255 = totalmente opaco.
    expect(pixels.getUint8(3), 255,
        reason: 'la tarjeta se exportó sobre transparencia; falta un fondo opaco');
  });

  testWidgets('con el top lleno, la tarjeta sigue incluyendo las canciones', (tester) async {
    // El caso que se rompía en el dispositivo: 10 artistas empujaban la
    // sección de canciones fuera de una tarjeta de alto fijo.
    await _pumpCard(tester, _data(artists: 10, songs: 10));

    expect(find.text('Artista 9'), findsWidgets, reason: 'falta el último artista');
    // StatisticsView colapsa a 5 canciones sin `expanded`, así que la
    // primera tiene que estar presente aunque la lista de artistas sea larga.
    expect(find.text('Canción 0'), findsWidgets, reason: 'la sección de canciones se perdió');
  });

  test('nunca se lee debugNeedsPaint fuera de un assert — lanza en release', () {
    // El bug real: "LateInitializationError: Local 'result' has not been
    // initialized" al tocar "Compartir imagen" en el APK real, pero nunca en
    // `flutter test` — los tests corren con los asserts activos, como un
    // build debug, y `debugNeedsPaint` sólo se rompe cuando el `assert()`
    // que lo rodea se descarta entero en release (Flutter mismo lo
    // documenta: "In release builds, this throws"). Un test normal jamás
    // iba a atrapar esto; sólo grepear el patrón peligroso lo hace.
    final source = File('lib/services/share_image_service.dart').readAsStringSync();
    expect(
      source.contains('.debugNeedsPaint'),
      isFalse,
      reason: 'debugNeedsPaint es solo de depuración: leerlo fuera de un assert() lanza en release.',
    );
  });
}
