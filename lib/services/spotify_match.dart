import 'download_source.dart';
import 'spotify_service.dart';

/// Diferencia de duración que se acepta como "misma canción, sin dudarlo".
const goodMatchToleranceSeconds = 3;

/// Por encima de esto, la coincidencia se descarta — regla rescatada del
/// `searchAndDownload` original (ver CLAUDE.md, Fase 8): más vale no
/// descargar nada que entregar la canción equivocada (versión en vivo,
/// cover, remix…) sin que el usuario se entere.
const maxMatchToleranceSeconds = 30;

/// El resultado de intentar emparejar una pista de Spotify con un vídeo de
/// YouTube. `youtubeTrack` es `null` si no hubo ningún candidato comparable.
class SpotifyMatch {
  final SpotifyTrackInfo original;
  final RemoteTrack? youtubeTrack;
  final int? durationDiffSeconds;

  const SpotifyMatch({
    required this.original,
    this.youtubeTrack,
    this.durationDiffSeconds,
  });

  /// True si hay coincidencia y está dentro del margen aceptable — esto es
  /// lo único que decide si la pista entra en la descarga por lotes.
  bool get isAcceptable =>
      youtubeTrack != null && durationDiffSeconds != null && durationDiffSeconds! <= maxMatchToleranceSeconds;

  /// Coincidencia "limpia", sin necesidad de revisar. `isAcceptable` ya lo
  /// implica; existe aparte sólo para matizar la UI (aceptable-pero-revisa
  /// vs. buena sin más).
  bool get isGoodMatch => isAcceptable && durationDiffSeconds! <= goodMatchToleranceSeconds;
}

/// Elige, entre [candidates], el que tenga la duración más cercana a
/// [targetDurationSeconds]. Nunca compara por título/artista — son mucho
/// menos fiables entre plataformas (traducciones, "(Official Video)",
/// mayúsculas distintas...) que la duración exacta en segundos.
///
/// Ignora candidatos sin duración conocida (no hay nada que comparar);
/// devuelve `null` si ninguno lo es.
RemoteTrack? pickClosestByDuration(List<RemoteTrack> candidates, int targetDurationSeconds) {
  RemoteTrack? best;
  int? bestDiff;
  for (final candidate in candidates) {
    if (candidate.durationSeconds <= 0) continue;
    final diff = (candidate.durationSeconds - targetDurationSeconds).abs();
    if (bestDiff == null || diff < bestDiff) {
      best = candidate;
      bestDiff = diff;
    }
  }
  return best;
}

/// Busca en YouTube el equivalente de [track] y evalúa la coincidencia.
/// No lanza por "no encontré nada" — un [SpotifyMatch] con `youtubeTrack:
/// null` es un resultado válido y esperado, no un error de red.
Future<SpotifyMatch> matchSpotifyTrack(
  SpotifyTrackInfo track,
  DownloadSource source, {
  int searchLimit = 5,
}) async {
  final query = '${track.artist} ${track.title}';
  final candidates = await source.search(query, limit: searchLimit);
  final best = pickClosestByDuration(candidates, track.durationSeconds);
  if (best == null) {
    return SpotifyMatch(original: track, youtubeTrack: null, durationDiffSeconds: null);
  }
  return SpotifyMatch(
    original: track,
    youtubeTrack: best,
    durationDiffSeconds: (best.durationSeconds - track.durationSeconds).abs(),
  );
}
