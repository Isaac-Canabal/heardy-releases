/// Estadísticas de escucha de un periodo, ya tipadas.
///
/// Existe por una razón concreta: hasta ahora los widgets de estadísticas
/// consumían directamente los `List<Map<String, dynamic>>` que devuelve
/// `DatabaseHelper`, y el perfil de un amigo les va a pasar mapas **parecidos
/// pero no idénticos** decodificados de JSON. Un límite tipado convierte esa
/// clase de error en un fallo de compilación en vez de un `null` a las tres
/// pantallas de distancia.
///
/// No es una entidad persistida, así que no implementa el
/// `toMap`/`fromMap`/`toJson`/`fromJson` completo de los modelos de `models/`:
/// sólo lo que hace falta para cruzar la frontera HTTP.
library;

class TopArtistStat {
  final String name;
  final int playCount;

  const TopArtistStat({required this.name, required this.playCount});

  factory TopArtistStat.fromMap(Map<String, dynamic> map) => TopArtistStat(
        name: (map['artist'] ?? map['name'] ?? '').toString(),
        playCount: (map['playCount'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toMap() => {'artist': name, 'playCount': playCount};
}

class TopSongStat {
  /// Id de la canción, que en esta app **es el hash del payload de audio**
  /// para todo lo importado o descargado tras el pivot. Viaja aunque hoy la
  /// pantalla no lo pinte: es lo que permitirá que, al mirar las estadísticas
  /// de un amigo, se use la carátula propia cuando resulta que se tiene la
  /// misma canción.
  final String songId;
  final String title;
  final String artist;

  /// Ruta local de la carátula. Vacía cuando no hay, y **siempre vacía** en
  /// unas estadísticas que vengan del servidor: es una ruta del dispositivo
  /// de otra persona y no significa nada aquí.
  final String artPath;
  final int playCount;

  const TopSongStat({
    required this.songId,
    required this.title,
    required this.artist,
    required this.artPath,
    required this.playCount,
  });

  factory TopSongStat.fromMap(Map<String, dynamic> map) => TopSongStat(
        songId: (map['id'] ?? map['songId'] ?? '').toString(),
        title: (map['title'] ?? '').toString(),
        artist: (map['artist'] ?? '').toString(),
        artPath: (map['artPath'] ?? '').toString(),
        playCount: (map['playCount'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toMap() => {
        'songId': songId,
        'title': title,
        'artist': artist,
        'playCount': playCount,
      };
}

class StatisticsData {
  final int totalPlays;
  final int totalListenSeconds;
  final List<TopArtistStat> topArtists;
  final List<TopSongStat> topSongs;

  const StatisticsData({
    required this.totalPlays,
    required this.totalListenSeconds,
    required this.topArtists,
    required this.topSongs,
  });

  const StatisticsData.empty()
      : totalPlays = 0,
        totalListenSeconds = 0,
        topArtists = const [],
        topSongs = const [];

  /// Sin nada que enseñar. Es el criterio que ya usaba la pantalla de Ajustes
  /// para decidir entre las tarjetas y el texto de "todavía no hay datos".
  bool get isEmpty => totalPlays == 0 && topSongs.isEmpty;

  /// Desde las filas crudas de `DatabaseHelper` (SQLite local).
  factory StatisticsData.fromRows({
    required int totalPlays,
    required int totalListenSeconds,
    required List<Map<String, dynamic>> topArtists,
    required List<Map<String, dynamic>> topSongs,
  }) {
    return StatisticsData(
      totalPlays: totalPlays,
      totalListenSeconds: totalListenSeconds,
      topArtists: topArtists.map(TopArtistStat.fromMap).toList(),
      topSongs: topSongs.map(TopSongStat.fromMap).toList(),
    );
  }

  /// Desde el JSON del servidor (estadísticas de un amigo).
  factory StatisticsData.fromMap(Map<String, dynamic> map) {
    return StatisticsData(
      totalPlays: (map['totalPlays'] as num?)?.toInt() ?? 0,
      totalListenSeconds: (map['totalListenSeconds'] as num?)?.toInt() ?? 0,
      topArtists: (map['topArtists'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(TopArtistStat.fromMap)
          .toList(),
      topSongs: (map['topSongs'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(TopSongStat.fromMap)
          .toList(),
    );
  }

  Map<String, dynamic> toMap() => {
        'totalPlays': totalPlays,
        'totalListenSeconds': totalListenSeconds,
        'topArtists': topArtists.map((a) => a.toMap()).toList(),
        'topSongs': topSongs.map((s) => s.toMap()).toList(),
      };
}
