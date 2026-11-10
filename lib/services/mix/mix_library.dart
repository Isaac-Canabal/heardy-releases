// Los mixes guardados en este dispositivo: listarlos, renombrarlos, guardarlos
// en una playlist (una fila normal de `songs` marcada como mix) y borrarlos.
// Todo es local; nada de aquí habla con un servidor.
import 'dart:io';
import 'dart:typed_data';

import '../../models/mix_record.dart';
import '../../models/song.dart';
import '../database_helper.dart';
import '../download_service.dart';
import 'mix_naming.dart';

class MixEntry {
  const MixEntry({required this.record, required this.sizeBytes, required this.savedSong});
  final MixRecord record;

  /// `null` si el archivo privado ya no está.
  final int? sizeBytes;

  /// La canción guardada en la biblioteca, si todavía existe.
  final Song? savedSong;
}

class MixDeletePreview {
  const MixDeletePreview({required this.sizeBytes, required this.savedSong, required this.savedSongPlaylistCount});
  final int? sizeBytes;
  final Song? savedSong;
  final int savedSongPlaylistCount;
}

/// [DownloadService.importPrivateAudio].
typedef MixSongSaver = Future<DownloadResult> Function({
  required String sourcePath,
  required String title,
  required String artist,
  required int durationSeconds,
  required String playlistId,
  Uint8List? coverBytes,
  bool isMix,
});

abstract class MixLibrary {
  /// El más reciente primero.
  Future<List<MixEntry>> list();
  Future<MixRecord> rename(MixRecord record, String name);
  Future<MixRecord> saveToPlaylist(MixRecord record, String playlistId);
  Future<MixDeletePreview> deletePreview(MixRecord record);
  Future<void> delete(MixRecord record, {required bool alsoSavedSong});
}

class LocalMixLibrary implements MixLibrary {
  LocalMixLibrary({DatabaseHelper? db, required MixSongSaver saver})
      : _db = db ?? DatabaseHelper.instance,
        _saver = saver;
  final DatabaseHelper _db;
  final MixSongSaver _saver;

  Future<int?> _size(String path) async {
    try {
      final f = File(path);
      return await f.exists() ? await f.length() : null;
    } catch (_) {
      return null;
    }
  }

  Future<Song?> _savedSong(MixRecord r) async => r.savedSongId == null ? null : _db.getSongById(r.savedSongId!);

  @override
  Future<List<MixEntry>> list() async => [
        for (final r in await _db.getMixes())
          MixEntry(record: r, sizeBytes: await _size(r.filePath), savedSong: await _savedSong(r)),
      ];

  @override
  Future<MixRecord> rename(MixRecord record, String name) async {
    final clean = normalizeMixName(name);
    if (clean == null || clean == record.name) return record;
    await _db.renameMix(record.id, clean);
    return record.copyWith(name: clean);
  }

  @override
  Future<MixRecord> saveToPlaylist(MixRecord record, String playlistId) async {
    Uint8List? cover;
    if (record.artPath.isNotEmpty) {
      try {
        final art = File(record.artPath);
        if (await art.exists()) cover = await art.readAsBytes();
      } catch (e) {
        print('Mix: no se pudo leer la carátula del mix (${e.runtimeType})');
      }
    }
    final result = await _saver(
      sourcePath: record.filePath,
      title: record.name,
      artist: combinedMixArtist(record.artistA, record.artistB),
      durationSeconds: (record.durationMs / 1000).round(),
      playlistId: playlistId,
      coverBytes: cover,
      isMix: true,
    );
    await _db.setMixSavedSong(record.id, result.song.id);
    return record.copyWith(savedSongId: result.song.id);
  }

  @override
  Future<MixDeletePreview> deletePreview(MixRecord record) async {
    final song = await _savedSong(record);
    return MixDeletePreview(
      sizeBytes: await _size(record.filePath),
      savedSong: song,
      savedSongPlaylistCount: song == null ? 0 : await _db.getPlaylistCountForSong(song.id),
    );
  }

  /// Borrado explícito: el archivo privado, su carátula y el registro; con
  /// [alsoSavedSong], también la canción guardada (fila y archivo real).
  @override
  Future<void> delete(MixRecord record, {required bool alsoSavedSong}) async {
    if (alsoSavedSong && record.savedSongId != null) {
      await _db.deleteSong(record.savedSongId!);
    }
    for (final path in [record.filePath, record.artPath]) {
      if (path.isEmpty) continue;
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (e) {
        print('Mix: no se pudo borrar un archivo del mix (${e.runtimeType})');
      }
    }
    await _db.deleteMixRecord(record.id);
  }
}

/// "4,2 MB" (una decimal por debajo de 10 MB).
String formatMixSize(int bytes, {String decimalSeparator = ','}) {
  final mb = bytes / (1024 * 1024);
  if (mb >= 10) return '${mb.round()} MB';
  final text = mb.toStringAsFixed(1).replaceAll('.', decimalSeparator);
  return '$text MB';
}

/// "3:21", o "1:02:05" pasada la hora.
String formatMixDuration(int durationMs) {
  final total = durationMs ~/ 1000;
  final h = total ~/ 3600, m = (total % 3600) ~/ 60, s = total % 60;
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}
