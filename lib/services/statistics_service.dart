/// Carga de estadísticas locales, fuera de la pantalla que las pinta.
///
/// Funciones de nivel superior y no una clase: no hay estado que guardar, y
/// así se prueban directamente contra una base `sqflite_common_ffi` sembrada,
/// sin renderizar nada — el mismo precedente que `missingPlaylistEntries()`.
library;

import '../models/statistics_data.dart';
import 'database_helper.dart';

/// Las cuatro consultas del periodo, en paralelo.
///
/// Periodos naturales en hora local (ver `DatabaseHelper`): "semana" desde el
/// lunes y "mes" desde el día 1. Cualquier cambio tiene que hacerse a la vez
/// aquí y en el servidor (library_store.py), o las estadísticas propias y las
/// que ve un amigo dejarían de coincidir y se leería como un fallo.
Future<StatisticsData> loadLocalStatistics({
  required bool isWeek,
  DatabaseHelper? db,
}) async {
  final helper = db ?? DatabaseHelper.instance;
  final results = await Future.wait([
    isWeek ? helper.getTotalPlaysThisWeek() : helper.getTotalPlaysThisMonth(),
    isWeek ? helper.getTotalListenTimeThisWeek() : helper.getTotalListenTimeThisMonth(),
    isWeek ? helper.getTopArtistsThisWeek() : helper.getTopArtistsThisMonth(),
    isWeek ? helper.getTopSongsThisWeek(limit: 10) : helper.getTopSongsThisMonth(limit: 10),
  ]);

  return StatisticsData.fromRows(
    totalPlays: results[0] as int,
    totalListenSeconds: results[1] as int,
    topArtists: foldTopArtists(results[2] as List<Map<String, dynamic>>),
    topSongs: results[3] as List<Map<String, dynamic>>,
  );
}

/// Pliega filas `(artist, playCount)` por nombre normalizado (trim, espacios
/// colapsados, `toLowerCase()`) y se queda con las `limit` más escuchadas.
///
/// Necesario porque SQLite agrupa `s.artist` con colación binaria: "Bad
/// Bunny" y "bad bunny" llegan aquí como dos filas separadas. La clave de
/// plegado replica a propósito `compute_artist_key` del servidor
/// (`server/app/library_store.py`) para que el top de artistas propio y el
/// que ve un amigo coincidan. El nombre mostrado es la variante más
/// escuchada dentro del grupo — mismo criterio que el `mode()` del servidor
/// — no la primera que aparezca.
List<Map<String, dynamic>> foldTopArtists(
  List<Map<String, dynamic>> rows, {
  int limit = 5,
}) {
  final byKey = <String, _ArtistFold>{};
  for (final row in rows) {
    final rawName = (row['artist'] as String?) ?? '';
    final key = rawName.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
    if (key.isEmpty) continue;
    final playCount = (row['playCount'] as num?)?.toInt() ?? 0;

    final fold = byKey.putIfAbsent(key, () => _ArtistFold());
    fold.totalPlayCount += playCount;
    if (playCount > fold.bestVariantPlayCount) {
      fold.bestVariantPlayCount = playCount;
      fold.bestVariantName = rawName;
    }
  }

  final folded = byKey.values
      .map((f) => {'artist': f.bestVariantName, 'playCount': f.totalPlayCount})
      .toList()
    ..sort((a, b) => (b['playCount'] as int).compareTo(a['playCount'] as int));

  return folded.take(limit).toList();
}

class _ArtistFold {
  int totalPlayCount = 0;
  int bestVariantPlayCount = 0;
  String bestVariantName = '';
}

/// `45 s` / `12m` / `3h 5m`. Movida tal cual desde `settings_screen.dart`.
String formatListenTime(int totalSeconds) {
  if (totalSeconds < 60) return '$totalSeconds s';
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  if (hours > 0) return '${hours}h ${minutes}m';
  return '${minutes}m';
}
