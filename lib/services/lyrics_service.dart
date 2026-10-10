import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'app_log.dart';
import 'lyrics_logic.dart';

class LyricLine {
  final Duration time;
  final String text;
  final List<LyricWord> words;
  final Duration? wordsEnd;
  LyricLine(this.time, this.text, {this.words = const [], this.wordsEnd});
}

/// Lo que devuelve una fuente de letras: el texto crudo (formato .lrc si
/// [synced], texto plano si no) y si trae marcas de tiempo.
class _LyricsResult {
  final String text;
  final bool synced;
  const _LyricsResult(this.text, {required this.synced});
}

const _userAgent = 'Heardy/1.0.0 (https://github.com/Isaac-Canabal/Heardy)';

/// Timeout de cada llamada de red individual. Con hasta 5 llamadas
/// secuenciales posibles en el peor caso (exacto + 2 búsquedas de LRCLIB +
/// búsqueda y letra de NetEase), 10s por llamada —lo que tenía LRCLIB solo—
/// dejaba un techo de 40-50s: `DownloadService.download()` precarga la letra
/// de cada canción recién descargada y la espera antes de terminar, así que
/// ese techo le pega directo al tiempo de descarga, no sólo a la pantalla de
/// letras. 4s mantiene un techo total parecido al de antes (2 fuentes × 10s)
/// repartido entre más fuentes.
const _networkTimeout = Duration(seconds: 4);

/// Elige, de los resultados de búsqueda de NetEase Cloud Music, el más
/// cercano en duración a [targetDurationSeconds] — misma regla que
/// `spotify_match.dart` (ver CLAUDE.md, "Spotify bridge"): comparar por
/// duración, nunca por título/artista, porque esos textos no son fiables
/// entre plataformas (traducciones, mayúsculas distintas, "(Live)"...).
/// Sin duración conocida (`<= 0`, letra pedida para una canción sin duración
/// local) se toma el primer resultado tal cual, que es lo mejor que se puede
/// hacer con lo que hay. Función pura y top-level a propósito: es lo único
/// de este archivo que se puede probar sin red.
Map<String, dynamic>? pickNeteaseCandidate(
  List<dynamic> songs,
  int targetDurationSeconds, {
  int maxToleranceSeconds = 30,
}) {
  if (songs.isEmpty) return null;
  if (targetDurationSeconds <= 0) return songs.first as Map<String, dynamic>;

  Map<String, dynamic>? best;
  int? bestDiff;
  for (final raw in songs) {
    final song = raw as Map<String, dynamic>;
    final durationMs = (song['duration'] as num?)?.toInt() ?? 0;
    if (durationMs <= 0) continue;
    final diff = (durationMs ~/ 1000 - targetDurationSeconds).abs();
    if (diff > maxToleranceSeconds) continue;
    if (bestDiff == null || diff < bestDiff) {
      best = song;
      bestDiff = diff;
    }
  }
  return best;
}

class LyricsService {
  static final LyricsService instance = LyricsService._init();
  LyricsService._init();

  Future<String> _getLyricsFilePath(String songId) async {
    final docDir = await getApplicationDocumentsDirectory();
    final lyricsDir = Directory('${docDir.path}/lyrics');
    if (!await lyricsDir.exists()) {
      await lyricsDir.create(recursive: true);
    }
    return '${lyricsDir.path}/$songId.lrc';
  }

  /// Limpia título/artista para que las distintas fuentes los reconozcan
  /// mejor. Importa sobre todo para canciones indie importadas con
  /// metadatos ruidosos: título de YouTube con adornos, canal "Artista -
  /// Topic", ediciones con "(Remastered 2019)" o "(feat. X)" que casi
  /// ninguna fuente de letras indexa tal cual.
  String _cleanName(String text) {
    return text
        .replaceAll(RegExp(r'\((Official\s+)?(Video|Audio|Lyrics|Lyric\s+Video|HQ|HD)\)', caseSensitive: false), '')
        .replaceAll(RegExp(r'\[(Official\s+)?(Video|Audio|Lyrics|Lyric\s+Video|HQ|HD)\]', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s-\sTopic$', caseSensitive: false), '')
        .replaceAll(RegExp(r'\((feat\.?|ft\.?|featuring)\s+[^)]*\)', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s-\s?(feat\.?|ft\.?|featuring)\s+.*$', caseSensitive: false), '')
        .replaceAll(RegExp(r'\((Remaster(ed)?|Deluxe|Bonus\s+Track)[^)]*\)', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Fetches and caches lyrics. Returns null if not found.
  ///
  /// Prueba varias fuentes en orden, cada una independiente de las demás —
  /// un fallo de red o "no encontrado" en una no impide seguir con la
  /// próxima. Se prioriza SIEMPRE una letra sincronizada por sobre una
  /// plana, aunque venga de una fuente que se probó después: quedarse con la
  /// primera plana que apareciera es justo el bug que hacía que canciones
  /// con letra sincronizada disponible en otra fuente (o más abajo en la
  /// misma búsqueda) se mostraran sin resaltado ni avance en el tiempo. Sólo
  /// si ninguna fuente tiene una sincronizada se cae a la mejor letra plana
  /// encontrada — mostrar texto sin resaltar sigue siendo mejor que nada
  /// para una canción indie poco conocida.
  Future<String?> getLyrics({
    required String songId,
    required String title,
    required String artist,
    required int durationSeconds,
  }) async {
    // 1. Check local file cache
    final localPath = await _getLyricsFilePath(songId);
    final localFile = File(localPath);
    if (await localFile.exists()) {
      final cachedLyrics = await localFile.readAsString();
      if (cachedLyrics.isNotEmpty) return cachedLyrics;
    }

    final cleanTitle = _cleanName(title);
    final cleanArtist = _cleanName(artist);

    _LyricsResult? plainFallback;
    for (final source in <Future<_LyricsResult?> Function()>[
      () => _fromLrclibExact(cleanTitle, cleanArtist, durationSeconds),
      () => _fromLrclibSearch('$cleanTitle $cleanArtist'),
      // Sin artista: cubre canciones importadas con el artista mal puesto
      // (canal "Topic", subida genérica) donde sólo el título coincide.
      if (cleanArtist.isNotEmpty) () => _fromLrclibSearch(cleanTitle),
      () => _fromNetease(cleanTitle, cleanArtist, durationSeconds),
    ]) {
      _LyricsResult? result;
      try {
        result = await source();
      } catch (e) {
        appLog('Una fuente de letras falló: $e');
        continue;
      }
      if (result == null) continue;
      if (result.synced) {
        await localFile.writeAsString(result.text);
        return result.text;
      }
      plainFallback ??= result;
    }

    if (plainFallback != null) {
      await localFile.writeAsString(plainFallback.text);
      return plainFallback.text;
    }
    return null;
  }

  Future<_LyricsResult?> _fromLrclibExact(String title, String artist, int durationSeconds) async {
    final uri = Uri.parse('https://lrclib.net/api/get').replace(queryParameters: {
      'track_name': title,
      'artist_name': artist,
      'duration': durationSeconds.toString(),
    });
    final response = await http.get(uri, headers: {'User-Agent': _userAgent}).timeout(_networkTimeout);
    if (response.statusCode != 200) return null;
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final synced = data['syncedLyrics'] as String?;
    if (synced != null && synced.isNotEmpty) return _LyricsResult(synced, synced: true);
    final plain = data['plainLyrics'] as String?;
    if (plain != null && plain.isNotEmpty) return _LyricsResult(plain, synced: false);
    return null;
  }

  /// Recorre TODOS los resultados de `/api/search` buscando primero uno con
  /// letra sincronizada antes de conformarse con texto plano — quedarse con
  /// el primero que tuviera cualquier letra dejaba fija (por el cache en
  /// disco) una versión sin sincronizar aunque otro resultado más abajo en
  /// la misma búsqueda sí la tuviera.
  Future<_LyricsResult?> _fromLrclibSearch(String query) async {
    final uri = Uri.parse('https://lrclib.net/api/search').replace(queryParameters: {'q': query});
    final response = await http.get(uri, headers: {'User-Agent': _userAgent}).timeout(_networkTimeout);
    if (response.statusCode != 200) return null;
    final results = jsonDecode(response.body) as List<dynamic>;
    String? fallbackPlain;
    for (final item in results) {
      final synced = item['syncedLyrics'] as String?;
      if (synced != null && synced.isNotEmpty) return _LyricsResult(synced, synced: true);
      final plain = item['plainLyrics'] as String?;
      if (fallbackPlain == null && plain != null && plain.isNotEmpty) fallbackPlain = plain;
    }
    return fallbackPlain != null ? _LyricsResult(fallbackPlain, synced: false) : null;
  }

  /// NetEase Cloud Music: sin API oficial ni clave, igual que
  /// `spotify_service.dart` con el embed público de Spotify. Es un catálogo
  /// bastante distinto al de LRCLIB (fuerte en versiones/covers e indies que
  /// LRCLIB no siempre indexa), así que sirve de segunda opinión real, no de
  /// duplicado. El emparejamiento usa la misma regla que Spotify→YouTube
  /// ([pickNeteaseCandidate]): duración, nunca texto.
  Future<_LyricsResult?> _fromNetease(String title, String artist, int durationSeconds) async {
    final headers = {'User-Agent': _userAgent, 'Referer': 'https://music.163.com/'};
    final searchUri = Uri.parse('https://music.163.com/api/search/get/web').replace(queryParameters: {
      's': '$title $artist'.trim(),
      'type': '1',
      'offset': '0',
      'limit': '8',
    });
    final searchResponse = await http.get(searchUri, headers: headers).timeout(_networkTimeout);
    if (searchResponse.statusCode != 200) return null;
    final searchData = jsonDecode(searchResponse.body) as Map<String, dynamic>;
    final songs = (searchData['result'] as Map<String, dynamic>?)?['songs'] as List<dynamic>? ?? const [];
    final match = pickNeteaseCandidate(songs, durationSeconds);
    if (match == null) return null;

    final lyricUri = Uri.parse('https://music.163.com/api/song/lyric').replace(queryParameters: {
      'id': '${match['id']}',
      'lv': '1',
      'kv': '1',
      'tv': '-1',
    });
    final lyricResponse = await http.get(lyricUri, headers: headers).timeout(_networkTimeout);
    if (lyricResponse.statusCode != 200) return null;
    final lyricData = jsonDecode(lyricResponse.body) as Map<String, dynamic>;
    final lrc = (lyricData['lrc'] as Map<String, dynamic>?)?['lyric'] as String?;
    if (lrc == null || lrc.isEmpty) return null;
    return _LyricsResult(lrc, synced: true);
  }

  /// Parses .lrc styled string into LyricLines
  List<LyricLine> parseLrc(String lrcText) {
    final List<LyricLine> lines = [];
    final regExp = RegExp(r'^\[(\d+):(\d+)(?:\.(\d+))?\](.*)');

    for (final line in lrcText.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      final match = regExp.firstMatch(trimmed);
      if (match != null) {
        final min = int.parse(match.group(1)!);
        final sec = int.parse(match.group(2)!);
        final msStr = match.group(3) ?? '0';
        final ms = int.parse(msStr);

        // Convert centiseconds (2 digits) or milliseconds (3 digits) to ms
        final multiplier = msStr.length == 2 ? 10 : (msStr.length == 1 ? 100 : 1);
        final duration = Duration(
          minutes: min,
          seconds: sec,
          milliseconds: ms * multiplier,
        );
        final parsed = parseLyricText(match.group(4)!, duration);
        lines.add(LyricLine(duration, parsed.text, words: parsed.words, wordsEnd: parsed.end));
      }
    }

    lines.sort((a, b) => a.time.compareTo(b.time));
    return lines;
  }
}
