import 'dart:io';
import 'dart:typed_data';

import 'waveform_logic.dart';

/// Un archivo pequeño por canción en almacenamiento privado de la app.
class WaveformCache {
  final Future<Directory> Function() _dir;

  WaveformCache(this._dir);

  /// Los ids pueden venir de ids heredados; se deja sólo un nombre seguro.
  static String fileNameFor(String songId) =>
      '${songId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.wave';

  Future<File> _file(String songId) async {
    final dir = await _dir();
    return File('${dir.path}${Platform.pathSeparator}${fileNameFor(songId)}');
  }

  Future<Uint8List?> read(String songId) async {
    try {
      final file = await _file(songId);
      if (!await file.exists()) return null;
      return decodeWaveform(await file.readAsBytes());
    } catch (_) {
      return null;
    }
  }

  Future<void> write(String songId, Uint8List peaks) async {
    try {
      final file = await _file(songId);
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(encodeWaveform(peaks), flush: true);
      await tmp.rename(file.path);
    } catch (_) {}
  }

  Future<void> delete(String songId) async {
    try {
      final file = await _file(songId);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
