// Caché de stems separados (voz e instrumental, f32le estéreo 44.1 kHz) y de su
// análisis, por canción y modelo, en almacenamiento privado de la app. Es solo
// una caché: se acota por tamaño y se vacía empezando por lo menos usado.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../mix_analysis.dart';

/// ~1 GiB: unas seis canciones de 4 minutos (dos stems f32 de ~85 MB cada uno).
const kDefaultStemCacheBytes = 1 << 30;

class CachedStems {
  CachedStems(this.key, this.directory, this.analysis);
  final String key, directory;
  final SongAnalysis? analysis;
  String get vocalsPath => '$directory${Platform.pathSeparator}vocals.f32';
  String get instrumentalPath => '$directory${Platform.pathSeparator}instrumental.f32';
  String get _analysisPath => '$directory${Platform.pathSeparator}analysis.json';
  String get _marker => '$directory${Platform.pathSeparator}complete';
}

class StemCache {
  StemCache(this.rootPath, {this.maxBytes = kDefaultStemCacheBytes, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final String rootPath;
  final int maxBytes;
  final DateTime Function() _clock;

  /// Clave de directorio: los ids de canción heredados pueden traer cualquier
  /// carácter, así que se usa un hash.
  static String keyFor(String songId, String modelId) =>
      sha256.convert(utf8.encode('$songId\u0000$modelId')).toString().substring(0, 24);

  CachedStems _entry(String key, [SongAnalysis? a]) => CachedStems(key, '$rootPath${Platform.pathSeparator}$key', a);

  /// Entrada completa o `null`. Un acierto cuenta como uso reciente.
  Future<CachedStems?> lookup(String songId, String modelId) async {
    final e = _entry(keyFor(songId, modelId));
    if (!await File(e._marker).exists() ||
        !await File(e.vocalsPath).exists() ||
        !await File(e.instrumentalPath).exists()) {
      return null;
    }
    await File(e._marker).setLastModified(_clock());
    SongAnalysis? a;
    try {
      final f = File(e._analysisPath);
      if (await f.exists()) a = SongAnalysis.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
    } catch (err) {
      print('Mix: análisis en caché ilegible, se recalcula ($err)');
    }
    return _entry(e.key, a);
  }

  /// Directorio vacío para escribir una entrada nueva; no cuenta hasta [commit].
  Future<CachedStems> begin(String songId, String modelId) async {
    final e = _entry(keyFor(songId, modelId));
    final d = Directory(e.directory);
    if (await d.exists()) await d.delete(recursive: true);
    await d.create(recursive: true);
    return e;
  }

  Future<void> commit(CachedStems e) async {
    final m = File(e._marker);
    await m.writeAsString('1');
    await m.setLastModified(_clock());
  }

  Future<void> abort(CachedStems e) async {
    final d = Directory(e.directory);
    if (await d.exists()) await d.delete(recursive: true);
  }

  Future<void> saveAnalysis(String songId, String modelId, SongAnalysis a) async {
    final e = _entry(keyFor(songId, modelId));
    if (!await Directory(e.directory).exists()) return;
    await File(e._analysisPath).writeAsString(jsonEncode(a.toJson()));
  }

  int _dirBytes(Directory d) {
    var n = 0;
    for (final f in d.listSync(recursive: true).whereType<File>()) {
      n += f.lengthSync();
    }
    return n;
  }

  int sizeBytes() {
    final root = Directory(rootPath);
    return root.existsSync() ? _dirBytes(root) : 0;
  }

  /// Borra entradas, la de uso más antiguo primero, hasta quedar en
  /// [maxBytes]; las incompletas (trabajos interrumpidos) primero de todo.
  /// [keepKeys] no se tocan. Devuelve los bytes liberados.
  Future<int> evict({Set<String> keepKeys = const {}}) async {
    final root = Directory(rootPath);
    if (!await root.exists()) return 0;
    final entries = <(Directory, DateTime, int)>[];
    var total = 0;
    for (final d in root.listSync().whereType<Directory>()) {
      final key = d.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final size = _dirBytes(d);
      total += size;
      if (keepKeys.contains(key)) continue;
      final marker = File('${d.path}${Platform.pathSeparator}complete');
      final used = marker.existsSync() ? marker.lastModifiedSync() : DateTime.fromMillisecondsSinceEpoch(0);
      entries.add((d, used, size));
    }
    entries.sort((a, b) => a.$2.compareTo(b.$2));
    var freed = 0;
    for (final (d, _, size) in entries) {
      if (total <= maxBytes) break;
      try {
        await d.delete(recursive: true);
        total -= size;
        freed += size;
      } catch (err) {
        print('Mix: no se pudo vaciar una entrada de la caché ($err)');
      }
    }
    return freed;
  }
}
