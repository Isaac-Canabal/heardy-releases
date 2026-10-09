import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/song.dart';
import 'cover_art.dart';
import 'database_helper.dart';

/// Qué canciones pueden recuperar carátula: las que no tienen (o la perdieron
/// del disco) y traen un enlace de origen de YouTube del que sacarla. Pura,
/// para poder probarla sin base ni red; [artworkExists] es la comprobación de
/// archivo, inyectable.
List<Song> songsNeedingArtwork(
  Iterable<Song> songs, {
  required bool Function(String artPath) artworkExists,
}) {
  return [
    for (final song in songs)
      if ((song.artPath.isEmpty || !artworkExists(song.artPath)) &&
          youtubeVideoIdFrom(song.sourceUrl) != null)
        song,
  ];
}

/// Vuelve a bajar las carátulas que faltan.
///
/// Existe porque las descargas anteriores a que las miniaturas llegaran en
/// JPEG quedaron sin carátula (el WebP se descartaba en silencio), y ésas no
/// se pueden arreglar reescaneando: el archivo tampoco la tiene dentro. Lo
/// que sí tienen es `sourceUrl`, y con el id de YouTube la carátula se pide
/// directo a i.ytimg.com — sin pasar por el servidor de descargas ni gastar
/// su presupuesto.
class ArtworkRepairService {
  final DatabaseHelper _db;
  final http.Client Function() _clientFactory;

  ArtworkRepairService({
    DatabaseHelper? db,
    http.Client Function()? clientFactory,
  })  : _db = db ?? DatabaseHelper.instance,
        _clientFactory = clientFactory ?? (() => http.Client());

  /// Devuelve cuántas carátulas se recuperaron. [onProgress] recibe
  /// (hechas, total) por canción.
  Future<int> repairMissing({void Function(int done, int total)? onProgress}) async {
    final pending = songsNeedingArtwork(
      await _db.getSongs(),
      artworkExists: (path) => File(path).existsSync(),
    );
    if (pending.isEmpty) return 0;

    var repaired = 0;
    final client = _clientFactory();
    try {
      for (var i = 0; i < pending.length; i++) {
        final song = pending[i];
        final videoId = youtubeVideoIdFrom(song.sourceUrl)!;
        final bytes = await fetchCoverArt(client, '', videoId);
        if (bytes != null) {
          final artPath = await saveCoverArt(song.id, bytes);
          if (artPath.isNotEmpty) {
            await _db.updateSongArtPath(song.id, artPath);
            repaired++;
          }
        }
        onProgress?.call(i + 1, pending.length);
      }
    } finally {
      client.close();
    }
    return repaired;
  }
}
