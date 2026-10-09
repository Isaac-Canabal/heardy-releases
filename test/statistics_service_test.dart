// Cubre `loadLocalStatistics` contra una base sqflite_common_ffi sembrada a
// mano, sin renderizar nada. Antes del refactor de la Fase 1 estas consultas
// vivían dentro de `settings_screen.dart` y no había forma de probarlas sin
// montar la pantalla entera de Ajustes.
//
// Las filas de `play_history` se insertan con SQL directo a propósito:
// `DatabaseHelper.recordPlay` usa `DateTime.now()`, así que es el único modo de
// controlar la fecha y poder ejercitar los límites de periodo.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:heardy/models/song.dart';
import 'package:heardy/services/database_helper.dart';
import 'package:heardy/services/statistics_service.dart';

Song _song(String id, String title, String artist) => Song(
      id: id,
      title: title,
      artist: artist,
      duration: 180,
      filePath: '',
      artPath: '',
      format: 'm4a',
      downloadDate: DateTime(2026, 1, 1),
      uri: 'content://fake/$id',
      fileHash: id,
      hashKind: 'mp4-mdat',
    );

Future<void> _recordPlayAt(String songId, DateTime when, int seconds) async {
  final db = await DatabaseHelper.instance.database;
  await db.insert('play_history', {
    'songId': songId,
    'playDate': when.toIso8601String(),
    'playDuration': seconds,
  });
}

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // Directorio propio: otros archivos de test borran su `heardy.db` en su
    // propio setUpAll, y compartir la ruta los haría pisarse entre sí.
    final sandbox = Directory.systemTemp.createTempSync('heardy_stats_test_');
    await databaseFactory.setDatabasesPath(sandbox.path);
    await databaseFactory.deleteDatabase(join(sandbox.path, 'heardy.db'));
  });

  setUp(() async {
    final db = await DatabaseHelper.instance.database;
    await db.delete('play_history');
    await db.delete('songs');
  });

  group('loadLocalStatistics', () {
    test('sin reproducciones devuelve datos vacíos, no null', () async {
      final data = await loadLocalStatistics(isWeek: true);

      expect(data.totalPlays, 0);
      expect(data.totalListenSeconds, 0);
      expect(data.topSongs, isEmpty);
      expect(data.topArtists, isEmpty);
      expect(data.isEmpty, isTrue);
    });

    test('cuenta reproducciones y tiempo escuchado del periodo', () async {
      final db = DatabaseHelper.instance;
      await db.insertSong(_song('s1', 'Canción uno', 'Artista A'));
      final now = DateTime.now();

      await _recordPlayAt('s1', now.subtract(const Duration(hours: 1)), 120);
      await _recordPlayAt('s1', now.subtract(const Duration(hours: 2)), 60);

      final data = await loadLocalStatistics(isWeek: true);

      expect(data.totalPlays, 2);
      expect(data.totalListenSeconds, 180);
      expect(data.topSongs.single.title, 'Canción uno');
      expect(data.topSongs.single.playCount, 2);
      expect(data.topSongs.single.songId, 's1');
      expect(data.isEmpty, isFalse);
    });

    test('la semana deja fuera lo de hace 10 días y el mes natural deja fuera el mes anterior', () async {
      final db = DatabaseHelper.instance;
      await db.insertSong(_song('s1', 'Reciente', 'Artista A'));
      await db.insertSong(_song('s2', 'Hace diez días', 'Artista B'));
      await db.insertSong(_song('s3', 'Mes anterior', 'Artista C'));
      final now = DateTime.now();

      await _recordPlayAt('s1', now, 100);
      // El inicio de la semana está como mucho 6 días atrás, así que 10 días
      // siempre cae fuera de "esta semana".
      await _recordPlayAt('s2', now.subtract(const Duration(days: 10)), 200);
      // El mes es natural (desde el día 1): el último día del mes anterior
      // siempre cae fuera, sin depender del día en que corra el test.
      final lastDayOfPreviousMonth =
          DateTime(now.year, now.month, 1).subtract(const Duration(days: 1));
      await _recordPlayAt('s3', lastDayOfPreviousMonth, 400);

      final week = await loadLocalStatistics(isWeek: true);
      expect(week.totalPlays, 1);
      expect(week.totalListenSeconds, 100);
      expect(week.topSongs.map((s) => s.title), ['Reciente']);

      // Hace 10 días solo cuenta en el mes si seguimos más allá del día 10.
      final tenDaysAgoInMonth = now.day > 10;
      final month = await loadLocalStatistics(isWeek: false);
      expect(month.totalPlays, tenDaysAgoInMonth ? 2 : 1);
      expect(month.totalListenSeconds, tenDaysAgoInMonth ? 300 : 100);
      expect(month.topSongs.map((s) => s.title), contains('Reciente'));
      expect(month.topSongs.map((s) => s.title), isNot(contains('Mes anterior')));
    });

    test('el mes es una ventana rodante de 30 días: lo de hace 40 no cuenta', () async {
      final db = DatabaseHelper.instance;
      await db.insertSong(_song('s1', 'Antigua', 'Artista A'));
      await _recordPlayAt('s1', DateTime.now().subtract(const Duration(days: 40)), 300);

      final month = await loadLocalStatistics(isWeek: false);

      expect(month.totalPlays, 0);
      expect(month.isEmpty, isTrue);
    });

    test('agrupa por artista y ordena por número de reproducciones', () async {
      final db = DatabaseHelper.instance;
      await db.insertSong(_song('s1', 'Uno', 'Artista A'));
      await db.insertSong(_song('s2', 'Dos', 'Artista A'));
      await db.insertSong(_song('s3', 'Tres', 'Artista B'));
      final now = DateTime.now();

      await _recordPlayAt('s1', now.subtract(const Duration(minutes: 10)), 60);
      await _recordPlayAt('s2', now.subtract(const Duration(minutes: 20)), 60);
      await _recordPlayAt('s3', now.subtract(const Duration(minutes: 30)), 60);

      final data = await loadLocalStatistics(isWeek: true);

      expect(data.topArtists.first.name, 'Artista A');
      expect(data.topArtists.first.playCount, 2);
      expect(data.topArtists.last.name, 'Artista B');
      expect(data.topArtists.last.playCount, 1);
    });

    test('agrupa el mismo artista sin importar mayúsculas/espacios', () async {
      final db = DatabaseHelper.instance;
      await db.insertSong(_song('s1', 'Uno', 'Bad Bunny'));
      await db.insertSong(_song('s2', 'Dos', 'bad bunny'));
      await db.insertSong(_song('s3', 'Tres', '  Bad   Bunny  '));
      await db.insertSong(_song('s4', 'Cuatro', 'Otro Artista'));
      final now = DateTime.now();

      await _recordPlayAt('s1', now.subtract(const Duration(minutes: 10)), 60);
      await _recordPlayAt('s2', now.subtract(const Duration(minutes: 20)), 60);
      await _recordPlayAt('s2', now.subtract(const Duration(minutes: 21)), 60);
      await _recordPlayAt('s3', now.subtract(const Duration(minutes: 30)), 60);
      await _recordPlayAt('s4', now.subtract(const Duration(minutes: 40)), 60);

      final data = await loadLocalStatistics(isWeek: true);

      expect(data.topArtists.length, 2);
      // Las tres variantes de "Bad Bunny" se suman en un solo grupo (4
      // reproducciones), y el nombre mostrado es la variante más escuchada
      // dentro del grupo ("bad bunny", con 2).
      expect(data.topArtists.first.name, 'bad bunny');
      expect(data.topArtists.first.playCount, 4);
      expect(data.topArtists.last.name, 'Otro Artista');
      expect(data.topArtists.last.playCount, 1);
    });

    test('el top de canciones se corta en 10', () async {
      final db = DatabaseHelper.instance;
      final now = DateTime.now();
      for (var i = 0; i < 12; i++) {
        await db.insertSong(_song('s$i', 'Canción $i', 'Artista'));
        // Más reproducciones a las primeras, para que el orden sea determinista.
        for (var play = 0; play < 12 - i; play++) {
          await _recordPlayAt('s$i', now.subtract(Duration(minutes: i * 10 + play)), 30);
        }
      }

      final data = await loadLocalStatistics(isWeek: true);

      expect(data.topSongs.length, 10);
      expect(data.topSongs.first.title, 'Canción 0');
    });
  });

  group('foldTopArtists', () {
    test('respeta el límite tras plegar, no antes', () {
      final rows = [
        {'artist': 'A', 'playCount': 5},
        {'artist': 'a', 'playCount': 3},
        {'artist': 'B', 'playCount': 4},
        {'artist': 'C', 'playCount': 1},
      ];

      final folded = foldTopArtists(rows, limit: 2);

      expect(folded.length, 2);
      expect(folded[0]['artist'], 'A');
      expect(folded[0]['playCount'], 8);
      expect(folded[1]['artist'], 'B');
      expect(folded[1]['playCount'], 4);
    });

    test('descarta filas de artista vacío', () {
      final rows = [
        {'artist': '', 'playCount': 5},
        {'artist': '   ', 'playCount': 5},
      ];

      expect(foldTopArtists(rows), isEmpty);
    });
  });

  group('formatListenTime', () {
    test('bajo un minuto, en segundos', () {
      expect(formatListenTime(0), '0 s');
      expect(formatListenTime(59), '59 s');
    });

    test('minutos exactos y sueltos', () {
      expect(formatListenTime(60), '1m');
      expect(formatListenTime(3599), '59m');
    });

    test('horas con sus minutos', () {
      expect(formatListenTime(3600), '1h 0m');
      expect(formatListenTime(3660), '1h 1m');
      expect(formatListenTime(11100), '3h 5m');
    });
  });
}
