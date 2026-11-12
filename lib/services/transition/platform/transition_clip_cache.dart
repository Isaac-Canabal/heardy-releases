// Caché acotada (LRU por fecha de modificación) de los clips de transición ya
// renderizados: un WAV de 16 bits y un JSON lateral con los tiempos que el
// reproductor necesita. Vive en almacenamiento privado de la app; nunca se sube.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../transition_model.dart';

/// Súbelo cuando cambie el renderizador: invalida todos los clips guardados.
const kTransitionEngineVersion = 1;

const kDefaultTransitionClipCacheBytes = 300 << 20;

class CachedTransitionClip {
  const CachedTransitionClip(this.key, this.wavPath, this.meta);
  final String key;
  final String wavPath;
  final Map<String, dynamic> meta;
}

class TransitionClipCache {
  TransitionClipCache(this.rootPath, {this.maxBytes = kDefaultTransitionClipCacheBytes, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final String rootPath;
  final int maxBytes;
  final DateTime Function() _clock;

  static String keyFor(SongTransition transition, String fromSongId, String toSongId) {
    final payload = jsonEncode([kTransitionEngineVersion, fromSongId, toSongId, transition.toJson()]);
    return sha256.convert(utf8.encode(payload)).toString().substring(0, 32);
  }

  String _wav(String key) => '$rootPath${Platform.pathSeparator}$key.wav';
  String _json(String key) => '$rootPath${Platform.pathSeparator}$key.json';

  /// Ruta temporal donde escribir el WAV; no cuenta hasta [commit].
  Future<String> tempWavPath(String key) async {
    await Directory(rootPath).create(recursive: true);
    return '${_wav(key)}.tmp';
  }

  Future<CachedTransitionClip?> lookup(String key) async {
    final wav = File(_wav(key)), meta = File(_json(key));
    if (!await wav.exists() || !await meta.exists()) return null;
    try {
      final m = jsonDecode(await meta.readAsString());
      if (m is! Map<String, dynamic>) return null;
      final now = _clock();
      await wav.setLastModified(now);
      await meta.setLastModified(now);
      return CachedTransitionClip(key, wav.path, m);
    } catch (e) {
      print('Transición: metadatos del clip ilegibles, se vuelve a renderizar (${e.runtimeType})');
      return null;
    }
  }

  /// Convierte el WAV temporal en entrada de la caché (renombrado atómico) y
  /// vacía lo más antiguo si se pasa del límite.
  Future<CachedTransitionClip> commit(String key, Map<String, dynamic> meta) async {
    final metaTmp = File('${_json(key)}.tmp');
    await metaTmp.writeAsString(jsonEncode(meta));
    await File('${_wav(key)}.tmp').rename(_wav(key));
    await metaTmp.rename(_json(key));
    final now = _clock();
    await File(_wav(key)).setLastModified(now);
    await File(_json(key)).setLastModified(now);
    await evict(keepKeys: {key});
    return CachedTransitionClip(key, _wav(key), meta);
  }

  Future<void> remove(String key) async {
    for (final p in [_wav(key), _json(key), '${_wav(key)}.tmp', '${_json(key)}.tmp']) {
      try {
        final f = File(p);
        if (await f.exists()) await f.delete();
      } catch (e) {
        print('Transición: no se pudo borrar un clip de la caché (${e.runtimeType})');
      }
    }
  }

  int sizeBytes() {
    final root = Directory(rootPath);
    if (!root.existsSync()) return 0;
    return root.listSync().whereType<File>().fold(0, (n, f) => n + f.lengthSync());
  }

  /// Borra los temporales huérfanos y luego los clips menos usados hasta
  /// quedar en [maxBytes]. Devuelve los bytes liberados.
  Future<int> evict({Set<String> keepKeys = const {}}) async {
    final root = Directory(rootPath);
    if (!await root.exists()) return 0;
    var freed = 0;
    var total = 0;
    final entries = <String, (DateTime, int)>{};
    for (final f in root.listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      final size = f.lengthSync();
      if (name.endsWith('.tmp')) {
        if (keepKeys.any((k) => name.startsWith('$k.'))) continue;
        try {
          f.deleteSync();
          freed += size;
        } catch (_) {}
        continue;
      }
      total += size;
      final key = name.split('.').first;
      final when = f.lastModifiedSync();
      final prev = entries[key];
      entries[key] = (prev == null || when.isAfter(prev.$1) ? when : prev.$1, (prev?.$2 ?? 0) + size);
    }
    final order = entries.keys.where((k) => !keepKeys.contains(k)).toList()
      ..sort((a, b) {
        final c = entries[a]!.$1.compareTo(entries[b]!.$1);
        return c != 0 ? c : a.compareTo(b);
      });
    for (final k in order) {
      if (total <= maxBytes) break;
      await remove(k);
      total -= entries[k]!.$2;
      freed += entries[k]!.$2;
    }
    return freed;
  }
}
