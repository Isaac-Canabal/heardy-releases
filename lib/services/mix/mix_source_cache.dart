// Caché temporal del audio de canciones buscadas que se usan solo para un mix:
// en almacenamiento privado de la app (nunca en la carpeta de la biblioteca),
// acotada por tamaño y vaciada al volver a empezar. No crea filas en `songs`;
// para eso está "Descargar también a mi biblioteca", que va por la cola normal.
import 'dart:io';

import '../download_source.dart';

/// Unas seis canciones AAC de 4 minutos con holgura.
const kMixSourceCacheBytes = 400 * 1024 * 1024;

final _unsafe = RegExp(r'[^A-Za-z0-9_-]');

class MixSourceCache {
  MixSourceCache(this.rootPath, {this.maxBytes = kMixSourceCacheBytes});

  final String rootPath;
  final int maxBytes;

  String pathFor(String videoId) => '$rootPath${Platform.pathSeparator}${videoId.replaceAll(_unsafe, '_')}.m4a';

  /// Baja [track] (ya resuelto) si no está, y devuelve la ruta. Un corte deja
  /// solo el `.part`, que se borra.
  Future<String> fetch(RemoteTrack track, DownloadSource source,
      {ProgressCallback? onProgress, CancellationCheck? isCancelled}) async {
    final path = pathFor(track.id);
    final file = File(path);
    if (await file.exists() && await file.length() > 0) {
      await file.setLastModified(DateTime.now());
      return path;
    }
    await Directory(rootPath).create(recursive: true);
    final part = File('$path.part');
    try {
      await source.fetchAudio(track.id, part.path, onProgress: onProgress, isCancelled: isCancelled);
      await part.rename(path);
    } finally {
      if (await part.exists()) await part.delete();
    }
    return path;
  }

  /// Borra los más antiguos hasta caber en [maxBytes], salvo [keepVideoIds].
  Future<void> evict({Set<String> keepVideoIds = const {}}) async {
    final dir = Directory(rootPath);
    if (!await dir.exists()) return;
    final keep = {for (final id in keepVideoIds) pathFor(id)};
    final files = <(File, int, DateTime)>[];
    var total = 0;
    await for (final e in dir.list()) {
      if (e is! File) continue;
      final st = await e.stat();
      total += st.size;
      files.add((e, st.size, st.modified));
    }
    files.sort((x, y) => x.$3.compareTo(y.$3));
    for (final (f, size, _) in files) {
      if (total <= maxBytes) break;
      if (keep.contains(f.path)) continue;
      try {
        await f.delete();
        total -= size;
      } catch (e) {
        print('Mix: no se pudo borrar un temporal (${e.runtimeType})');
      }
    }
  }

  Future<void> clear() async {
    final dir = Directory(rootPath);
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}
