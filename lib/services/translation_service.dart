import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'app_log.dart';

/// Palabras funcionales comunes de cada idioma, usadas por [detectLyricsLanguage].
/// Sólo cubren español/inglés porque son los dos únicos idiomas que soporta
/// la app (`SettingsProvider.language`); una letra en un tercer idioma cae
/// al valor por defecto de esa función.
const Set<String> _spanishStopwords = {
  'que', 'de', 'la', 'el', 'en', 'y', 'a', 'los', 'las', 'un', 'una', 'unos',
  'unas', 'por', 'con', 'no', 'te', 'me', 'mi', 'tu', 'su', 'es', 'son',
  'para', 'como', 'pero', 'porque', 'ya', 'yo', 'tú', 'él', 'ella',
  'nosotros', 'ellos', 'qué', 'cómo', 'cuándo', 'dónde', 'esto', 'eso',
  'está', 'estoy', 'sí', 'se', 'lo', 'le', 'del', 'al', 'más', 'muy', 'todo',
  'todos', 'nada', 'nunca', 'siempre', 'aquí', 'así', 'sin', 'sobre', 'hay',
};

const Set<String> _englishStopwords = {
  'the', 'you', 'and', 'i', 'to', 'a', 'of', 'in', 'is', 'it', 'that', 'my',
  'your', 'me', 'we', 'this', 'for', 'on', 'be', 'with', 'was', 'are', 'but',
  'not', 'what', 'when', 'just', 'don\'t', 'can\'t', 'im', 'i\'m', 'all',
  'so', 'if', 'know', 'now', 'no', 'up', 'out', 'never', 'always', 'here',
  'there', 'want', 'they', 'she', 'he', 'her', 'him', 'have', 'do', 'oh',
};

/// Heurística ligera (sin red) para adivinar si un texto está en español o
/// en inglés: cuenta coincidencias de palabras funcionales de cada idioma.
/// No es un detector de idioma real — sólo distingue entre los dos idiomas
/// que soporta la app —, pero reemplaza la heurística anterior ("el idioma
/// original es siempre el opuesto al de la interfaz"), que traducía mal
/// cualquier canción cuyo idioma real coincidiera con el de la interfaz
/// (español a español mostrado como "sin coherencia", o inglés a inglés sin
/// ningún cambio).
String detectLyricsLanguage(String text) {
  final words = text
      .toLowerCase()
      .split(RegExp(r"[^a-záéíóúñü']+"))
      .where((w) => w.isNotEmpty);
  var esScore = 0;
  var enScore = 0;
  for (final w in words) {
    if (_spanishStopwords.contains(w)) esScore++;
    if (_englishStopwords.contains(w)) enScore++;
  }
  if (esScore == 0 && enScore == 0) return 'en';
  return esScore > enScore ? 'es' : 'en';
}

/// Traduce letras línea por línea vía MyMemory (api.mymemory.translated.net),
/// una API pública gratuita sin API key — mismo estilo que LyricsService/LRCLIB.
/// Cachea el resultado en disco para que abrir la traducción una segunda vez
/// no vuelva a golpear la red.
class TranslationService {
  static final TranslationService instance = TranslationService._init();
  TranslationService._init();

  static const int _maxConcurrentRequests = 6;

  /// MyMemory prioriza y sube la cuota gratuita anónima (5.000 → 50.000
  /// palabras/día) a quien manda un contacto en `de=` — documentado por
  /// ellos mismos. Sin esto, bajo carga, sus servidores pueden tardar varios
  /// segundos por línea; es la causa principal de que la traducción tardara
  /// casi toda la canción en aparecer. Se usa el correo de contacto público
  /// del proyecto (ya visible en Ajustes → Acerca de), no es un secreto.
  static const String _contactEmail = 'vainastech@gmail.com';

  Future<String> _getCacheFilePath(String songId, String targetLang) async {
    final docDir = await getApplicationDocumentsDirectory();
    final lyricsDir = Directory('${docDir.path}/lyrics');
    if (!await lyricsDir.exists()) {
      await lyricsDir.create(recursive: true);
    }
    return '${lyricsDir.path}/$songId.translated_$targetLang.json';
  }

  /// Traduce [lines] al idioma [targetLang] ('es'/'en'). El idioma de origen
  /// se detecta del propio texto (ver [detectLyricsLanguage]) en vez de
  /// asumirse fijo; si ya coincide con [targetLang] no hay nada que traducir
  /// y se devuelven las líneas tal cual, sin gastar peticiones.
  ///
  /// [onProgress], si se da, se llama después de cada tanda de líneas
  /// resueltas con el estado parcial acumulado (línea aún no traducida = su
  /// texto original) para que la pantalla pueda mostrar la traducción
  /// progresivamente en vez de esperar a que termine la canción entera.
  Future<List<String>> translateLines({
    required String songId,
    required List<String> lines,
    required String targetLang,
    void Function(List<String> partial)? onProgress,
  }) async {
    final cachePath = await _getCacheFilePath(songId, targetLang);
    final cacheFile = File(cachePath);
    if (await cacheFile.exists()) {
      try {
        final cached = jsonDecode(await cacheFile.readAsString()) as List<dynamic>;
        if (cached.length == lines.length) {
          return cached.map((e) => e as String).toList();
        }
      } catch (e) {
        appLog('Error leyendo cache de traducción: $e');
      }
    }

    final sampleText = lines.where((l) => l.trim().isNotEmpty).join(' ');
    final sourceLang = detectLyricsLanguage(sampleText);
    if (sourceLang == targetLang) {
      final same = List<String>.from(lines);
      try {
        await cacheFile.writeAsString(jsonEncode(same));
      } catch (e) {
        appLog('Error escribiendo cache de traducción: $e');
      }
      return same;
    }

    final translated = List<String>.from(lines);

    for (var start = 0; start < lines.length; start += _maxConcurrentRequests) {
      final end = (start + _maxConcurrentRequests < lines.length)
          ? start + _maxConcurrentRequests
          : lines.length;
      final chunk = List.generate(end - start, (i) => start + i);
      await Future.wait(chunk.map((i) async {
        final line = lines[i];
        if (line.trim().isEmpty) return;
        translated[i] = await _translateOne(line, sourceLang, targetLang) ?? line;
      }));
      onProgress?.call(List<String>.from(translated));
    }

    try {
      await cacheFile.writeAsString(jsonEncode(translated));
    } catch (e) {
      appLog('Error escribiendo cache de traducción: $e');
    }

    return translated;
  }

  Future<String?> _translateOne(String text, String sourceLang, String targetLang) async {
    try {
      final uri = Uri.https('api.mymemory.translated.net', '/get', {
        'q': text,
        'langpair': '$sourceLang|$targetLang',
        'de': _contactEmail,
      });
      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return null;
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final translatedText =
          json['responseData']?['translatedText'] as String?;
      if (translatedText == null || translatedText.isEmpty) return null;
      return translatedText;
    } catch (e) {
      appLog('Error traduciendo línea: $e');
      return null;
    }
  }
}
