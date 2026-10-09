import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'app_log.dart';

/// Las URLs de carátula que se van a intentar, en orden, para una pista.
///
/// Un `.m4a` sólo admite JPEG/PNG como carátula: `audio_metadata_reader`
/// descarta un WebP en silencio ("Skipping cover art") y la canción queda sin
/// carátula en disco. Las miniaturas `vi_webp/…/x.webp` de i.ytimg.com tienen
/// siempre su gemela `vi/…/x.jpg`, así que se prefiere ésa. Y como yt-dlp
/// lista `maxresdefault` aunque el vídeo no la tenga, `hqdefault.jpg` (que
/// existe para todo vídeo) queda de respaldo cuando se conoce el id.
List<String> coverArtCandidates(String thumbnailUrl, String videoId) {
  final candidates = <String>[];
  final url = thumbnailUrl.trim();
  if (url.isNotEmpty) {
    final query = url.indexOf('?');
    final path = query == -1 ? url : url.substring(0, query);
    if (path.contains('/vi_webp/') && path.endsWith('.webp')) {
      final withoutExt = path.substring(0, path.length - '.webp'.length);
      candidates.add('${withoutExt.replaceFirst('/vi_webp/', '/vi/')}.jpg');
    } else {
      candidates.add(url);
    }
  }
  final id = videoId.trim();
  if (id.isNotEmpty) {
    final fallback = 'https://i.ytimg.com/vi/$id/hqdefault.jpg';
    if (!candidates.contains(fallback)) candidates.add(fallback);
  }
  return candidates;
}

/// Id de vídeo a partir del enlace de origen de una canción; `null` si el
/// enlace no es de YouTube o no trae id.
String? youtubeVideoIdFrom(String? sourceUrl) {
  if (sourceUrl == null || sourceUrl.trim().isEmpty) return null;
  final uri = Uri.tryParse(sourceUrl.trim());
  if (uri == null) return null;
  final host = uri.host.toLowerCase();
  String? id;
  if (host == 'youtu.be') {
    id = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : null;
  } else if (host == 'youtube.com' || host.endsWith('.youtube.com') || host.endsWith('youtube-nocookie.com')) {
    id = uri.queryParameters['v'];
    if (id == null && uri.pathSegments.length >= 2) {
      final kind = uri.pathSegments[0];
      if (kind == 'shorts' || kind == 'embed' || kind == 'live') id = uri.pathSegments[1];
    }
  }
  if (id == null || !RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(id)) return null;
  return id;
}

/// Sniff por número mágico, no por la extensión de la URL: las miniaturas
/// de YouTube se sirven como .jpg pero pueden llegar en WebP.
String mimeForImage(Uint8List bytes) {
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return 'image/png';
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return 'image/webp';
  }
  return 'image/jpeg';
}

/// Baja la primera carátula que responda de [coverArtCandidates]. `null` si
/// ninguna lo hace: quedarse sin carátula no arruina nada — song_tile y
/// now_playing ya tienen el degradado por título como respaldo.
Future<Uint8List?> fetchCoverArt(
  http.Client client,
  String thumbnailUrl,
  String videoId,
) async {
  for (final candidate in coverArtCandidates(thumbnailUrl, videoId)) {
    try {
      final response = await client
          .get(Uri.parse(candidate))
          .timeout(const Duration(seconds: 20));
      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        return response.bodyBytes;
      }
      appLog('CoverArt: miniatura $candidate -> HTTP ${response.statusCode}');
    } catch (e) {
      appLog('CoverArt: no se pudo bajar la miniatura ($candidate): $e');
    }
  }
  return null;
}

/// Guarda la carátula en el directorio privado, misma convención que
/// MetadataService._saveArtwork: un archivo por canción, nunca un blob.
/// Devuelve '' (sin carátula, la convención de `Song.artPath`) si no se pudo.
Future<String> saveCoverArt(String songId, Uint8List bytes) async {
  try {
    final docDir = await getApplicationDocumentsDirectory();
    final thumbDir = Directory('${docDir.path}/thumbnails');
    if (!await thumbDir.exists()) {
      await thumbDir.create(recursive: true);
    }
    final ext = switch (mimeForImage(bytes)) {
      'image/png' => 'png',
      'image/webp' => 'webp',
      _ => 'jpg',
    };
    final path = '${thumbDir.path}/$songId.$ext';
    await File(path).writeAsBytes(bytes);
    return path;
  } catch (e) {
    appLog('CoverArt: no se pudo guardar la carátula de $songId: $e');
    return '';
  }
}
