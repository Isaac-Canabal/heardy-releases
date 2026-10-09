import 'download_source.dart';
import 'spotify_match.dart' show pickClosestByDuration, maxMatchToleranceSeconds, goodMatchToleranceSeconds;
import 'app_log.dart';

/// El resultado de intentar reconstruir una fila del índice de la nube
/// buscándola en YouTube — mismo criterio que el emparejamiento de Spotify
/// (`spotify_match.dart`): por proximidad de duración, nunca por
/// título/artista, y nunca se descarga nada sin enseñar antes la
/// coincidencia elegida (W7 del plan de escritorio, estrategia híbrida de
/// la Etapa 16 E-2).
///
/// No hay `sourceUrl` guardado en el índice de la nube (ver CLAUDE.md, Cloud
/// sync: sólo se guarda metadata, nunca nada que sólo signifique algo en el
/// dispositivo que lo subió) — así que lo que se reconstruye es "la misma
/// canción", no "el mismo archivo exacto". Si el resultado produce un audio
/// distinto al original, el hash será distinto y quedará como una canción
/// nueva — la deduplicación por hash de `DownloadService` es la que evita
/// duplicados cuando sí coincide.
class CloudSongMatch {
  final Map<String, dynamic> cloudSong;
  final RemoteTrack? youtubeTrack;
  final int? durationDiffSeconds;

  /// `true` cuando esto NO es una coincidencia elegida por parecido, sino el
  /// enlace original de verdad (por canción, o por venir de re-expandir la
  /// playlist de origen) — controla sólo la etiqueta que se enseña ("enlace
  /// original"), nunca si hace falta re-resolver antes de bajar: eso es
  /// [metadataComplete].
  final bool isExactSource;

  /// `true` sólo cuando [youtubeTrack] ya viene de un `resolve` completo de
  /// UNA canción (el camino de `sourceUrl` acá abajo). Un track que salió de
  /// re-expandir la playlist entera (`resolvePlaylist`, `extract_flat`) es
  /// igual de exacto en audio pero sigue siendo un listado aplanado sin
  /// metadata definitiva — DD6 exige resolverlo de nuevo en la cola antes de
  /// bajar un solo byte, o el archivo queda con tags a medias.
  final bool metadataComplete;

  const CloudSongMatch({
    required this.cloudSong,
    this.youtubeTrack,
    this.durationDiffSeconds,
    this.isExactSource = false,
    this.metadataComplete = false,
  });

  String get title => (cloudSong['title'] as String?) ?? '';
  String get artist => (cloudSong['artist'] as String?) ?? '';

  bool get isAcceptable =>
      youtubeTrack != null && durationDiffSeconds != null && durationDiffSeconds! <= maxMatchToleranceSeconds;

  bool get isGoodMatch => isAcceptable && durationDiffSeconds! <= goodMatchToleranceSeconds;
}

Future<CloudSongMatch> matchCloudSong(
  Map<String, dynamic> cloudSong,
  DownloadSource source, {
  int searchLimit = 5,
}) async {
  final title = (cloudSong['title'] as String?) ?? '';
  final artist = (cloudSong['artist'] as String?) ?? '';
  final durationSeconds = (cloudSong['durationSeconds'] as num?)?.toInt() ?? 0;

  // El enlace original, cuando la canción entró por una descarga: resolverlo
  // devuelve EXACTAMENTE el mismo audio, no un equivalente elegido por
  // parecido de duración. Se intenta primero y sólo se cae a la búsqueda si
  // falla (un vídeo retirado, un canal cerrado) — un enlace que ya no existe
  // no debe dejar la canción sin restaurar habiendo una alternativa.
  final sourceUrl = (cloudSong['sourceUrl'] as String?) ?? '';
  if (sourceUrl.isNotEmpty) {
    try {
      final track = await source.resolve(sourceUrl);
      return CloudSongMatch(
        cloudSong: cloudSong,
        youtubeTrack: track,
        // Cero a propósito: no es una coincidencia estimada, es el original.
        durationDiffSeconds: 0,
        isExactSource: true,
        // source.resolve() de UNA url es un resolve completo, no un listado
        // aplanado — no hace falta repetirlo en la cola (DD6).
        metadataComplete: true,
      );
    } catch (e) {
      appLog('matchCloudSong: el enlace original de "$title" ya no resuelve ($e), se busca uno equivalente');
    }
  }

  final query = '$artist $title'.trim();
  if (query.isEmpty) {
    return CloudSongMatch(cloudSong: cloudSong);
  }
  final candidates = await source.search(query, limit: searchLimit);
  final best = pickClosestByDuration(candidates, durationSeconds);
  if (best == null) {
    return CloudSongMatch(cloudSong: cloudSong);
  }
  return CloudSongMatch(
    cloudSong: cloudSong,
    youtubeTrack: best,
    durationDiffSeconds: (best.durationSeconds - durationSeconds).abs(),
  );
}

/// Agrupa [songs] (ya filtradas a las que faltan localmente) por la playlist
/// de la nube a la que pertenecen, usando [playlistSongs] (misma forma que
/// `CloudLibrary.playlistSongs`: filas `{playlistId, songId, orderIndex}`).
/// Una canción sin ninguna fila en `playlistSongs` cae bajo la clave `null`
/// — "suelta en la nube", el mismo concepto que la Bandeja local (D6), y
/// [groupMissingSongsByPlaylist] no intenta resolverla: la cola de descargas
/// exige un `playlistId` real (ver W7 del plan de escritorio), así que estas
/// quedan fuera de la restauración automática.
Map<String?, List<Map<String, dynamic>>> groupMissingSongsByPlaylist(
  List<Map<String, dynamic>> missingSongs,
  List<Map<String, dynamic>> playlistSongs,
) {
  final playlistIdBySongId = <String, String>{};
  for (final row in playlistSongs) {
    final songId = row['songId'] as String?;
    final playlistId = row['playlistId'] as String?;
    if (songId == null || playlistId == null) continue;
    // Una canción puede estar en varias playlists en la nube; para la
    // restauración automática alcanza con la primera — el resto de sus
    // membresías, si hacen falta, se arreglan a mano después de descargarla.
    playlistIdBySongId.putIfAbsent(songId, () => playlistId);
  }

  final grouped = <String?, List<Map<String, dynamic>>>{};
  for (final song in missingSongs) {
    final songId = song['songId'] as String?;
    final playlistId = songId == null ? null : playlistIdBySongId[songId];
    grouped.putIfAbsent(playlistId, () => []).add(song);
  }
  return grouped;
}
