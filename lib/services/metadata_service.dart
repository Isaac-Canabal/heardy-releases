import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:path_provider/path_provider.dart';

import 'library_storage.dart';
import 'replay_gain_logic.dart';
import 'app_log.dart';

/// Result of reading a song's tags, with every field already resolved
/// through the D5 fallback chain (tag → filename/folder → hard default).
class ExtractedMetadata {
  final String title;
  final String artist;
  final String? album;
  final int durationSeconds;
  final String artPath; // '' if no embedded cover was found

  const ExtractedMetadata({
    required this.title,
    required this.artist,
    required this.album,
    required this.durationSeconds,
    required this.artPath,
  });
}

class _FilenameGuess {
  final String title;
  final String? artist;
  const _FilenameGuess(this.title, this.artist);
}

/// Reads ID3v1/v2 and MP4/M4A tags for a SAF-imported song, with a
/// filename-parsing fallback when tags are missing or partial. See
/// CLAUDE.md D5 — do not re-derive these rules here.
class MetadataService {
  static final _leadingTrackNumber = RegExp(r'^\s*\d{1,3}[\s._\-)]+');
  static final _bracketJunk = RegExp(
    r'[\[(]\s*(official\s*(music\s*)?video|official\s*audio|lyrics?(\s*video)?|letra|con\s*letra|video\s*oficial|audio\s*oficial|hq|hd)\s*[\])]',
    caseSensitive: false,
  );
  static final _bitrateSuffix = RegExp(r'[\s._-]*\d{2,3}\s*kbps\s*$', caseSensitive: false);
  static final _collapseWhitespace = RegExp(r'\s+');
  static final _artistTitleSplit = RegExp(r'\s+-\s+');

  /// Por encima de este tamaño no se intenta leer tags y se cae al nombre del
  /// archivo; una imagen incrustada mayor que el tope no se guarda.
  static const int maxTagReadBytes = 512 * 1024 * 1024;
  static const int maxArtworkBytes = 8 * 1024 * 1024;
  static const int maxTagTextLength = 300;

  static bool canReadTags(int fileSize) => fileSize <= maxTagReadBytes;

  static bool isReasonableArtwork(int byteLength) => byteLength > 0 && byteLength <= maxArtworkBytes;

  final LibraryStorage _storage;

  MetadataService({LibraryStorage? storage}) : _storage = storage ?? defaultLibraryStorage();

  /// Copies [uri] to a temp file once, reads its tags, extracts any
  /// embedded cover to `<app documents>/thumbnails/<songId>.<ext>`, and
  /// deletes the temp copy — regardless of whether reading succeeded.
  /// [songId] is the song's stable id (the content hash), used to name the
  /// extracted artwork file.
  Future<ExtractedMetadata> extract({
    required String uri,
    required String fileName,
    required String songId,
    String? folderAlbum,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final ext = _extensionOf(fileName);
    final tempPath = '${tempDir.path}/heardy_tag_read_$songId${ext.isEmpty ? '' : '.$ext'}';
    final tempFile = File(tempPath);

    AudioMetadata? tags;
    try {
      await _storage.copyToLocalFile(uri, tempPath);
      final copiedSize = await tempFile.exists() ? await tempFile.length() : -1;
      appLog('MetadataService: copiado $fileName -> $tempPath (${copiedSize}b)');
      if (canReadTags(copiedSize)) {
        tags = readMetadata(tempFile, getImage: true);
        await _storeReplayGain(songId, ext, tempFile);
        appLog(
          'MetadataService: readMetadata($fileName) -> title=${tags.title} artist=${tags.artist} '
          'album=${tags.album} pictures=${tags.pictures.length} duration=${tags.duration}',
        );
      }
    } catch (e, s) {
      appLog('MetadataService: no se pudieron leer tags de $fileName ($uri): $e');
      appLog(s);
    } finally {
      try {
        if (await tempFile.exists()) await tempFile.delete();
      } catch (_) {}
    }

    final guess = _parseFilename(_withoutExtension(fileName));
    if (tags == null) {
      appLog('MetadataService: sin tags para $fileName, uso fallback de nombre -> title=${guess.title} artist=${guess.artist}');
    }

    final title = _clean(tags?.title) ?? guess.title;
    final artist = _clean(tags?.artist) ?? guess.artist ?? 'Desconocido';
    final album = _clean(tags?.album) ?? folderAlbum;
    final duration = tags?.duration?.inSeconds ?? 0;

    var artPath = '';
    final picture = tags?.pictures.isNotEmpty == true ? tags!.pictures.first : null;
    if (picture != null && isReasonableArtwork(picture.bytes.length)) {
      artPath = await _saveArtwork(songId, picture);
    }

    appLog('MetadataService: resultado final para $fileName -> title=$title artist=$artist album=$album artPath=$artPath');

    return ExtractedMetadata(
      title: title,
      artist: artist,
      album: album,
      durationSeconds: duration,
      artPath: artPath,
    );
  }

  static const _replayGainExtensions = {'mp3', 'flac', 'ogg', 'oga', 'opus'};

  static Future<File> _replayGainFile(String songId) async {
    final docDir = await getApplicationDocumentsDirectory();
    return File('${docDir.path}/replaygain/$songId.txt');
  }

  /// Ganancia ReplayGain guardada al importar la canción (dB), o null si el
  /// archivo no traía la etiqueta. No hay columna en `songs`: se guarda en un
  /// archivo pequeño por canción para no tocar el esquema.
  static Future<double?> storedReplayGainDb(String songId) async {
    try {
      final f = await _replayGainFile(songId);
      if (!await f.exists()) return null;
      return parseReplayGainDb(await f.readAsString());
    } catch (_) {
      return null;
    }
  }

  /// El lector de tags sólo expone ReplayGain para MP3 (TXXX) y FLAC/OGG/Opus
  /// (Vorbis); el M4A/MP4 de las descargas no se lee, y de hecho no lo trae.
  /// Los tipos concretos no son públicos, de ahí el acceso dinámico.
  Future<void> _storeReplayGain(String songId, String ext, File file) async {
    if (!_replayGainExtensions.contains(ext.toLowerCase())) return;
    try {
      final tag = readAllMetadata(file, getImage: false) as dynamic;
      final found = <String, String>{};
      try {
        final custom = tag.customMetadata;
        if (custom is Map) {
          for (final e in custom.entries) {
            found[e.key.toString()] = e.value.toString();
          }
        }
      } catch (_) {}
      for (final entry in {
        'REPLAYGAIN_TRACK_GAIN': () => tag.replayGainTrackGain,
        'REPLAYGAIN_ALBUM_GAIN': () => tag.replayGainAlbumGain,
      }.entries) {
        try {
          final v = entry.value();
          if (v is List && v.isNotEmpty) found[entry.key] = v.first.toString();
        } catch (_) {}
      }
      final db = pickTrackGainDb(found);
      if (db == null) return;
      final out = await _replayGainFile(songId);
      await out.parent.create(recursive: true);
      await out.writeAsString(db.toString());
    } catch (e) {
      appLog('MetadataService: sin ReplayGain para $songId: $e');
    }
  }

  Future<String> _saveArtwork(String songId, Picture picture) async {
    final docDir = await getApplicationDocumentsDirectory();
    final thumbDir = Directory('${docDir.path}/thumbnails');
    if (!await thumbDir.exists()) {
      await thumbDir.create(recursive: true);
    }
    final ext = picture.mimetype.toLowerCase().contains('png') ? 'png' : 'jpg';
    final path = '${thumbDir.path}/$songId.$ext';
    await File(path).writeAsBytes(picture.bytes);
    return path;
  }

  String? _clean(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    final runes = trimmed.runes;
    return runes.length > maxTagTextLength
        ? String.fromCharCodes(runes.take(maxTagTextLength))
        : trimmed;
  }

  String _extensionOf(String name) {
    final dot = name.lastIndexOf('.');
    return dot == -1 ? '' : name.substring(dot + 1);
  }

  String _withoutExtension(String name) {
    final dot = name.lastIndexOf('.');
    return dot == -1 ? name : name.substring(0, dot);
  }

  /// "01 - Bonnie Tyler - Total Eclipse of the Heart [Official Video]" ->
  /// artist "Bonnie Tyler", title "Total Eclipse of the Heart".
  _FilenameGuess _parseFilename(String nameWithoutExt) {
    var cleaned = nameWithoutExt.replaceAll(_leadingTrackNumber, '');
    cleaned = cleaned.replaceAll(_bracketJunk, '');
    cleaned = cleaned.replaceAll(_bitrateSuffix, '');
    cleaned = cleaned.replaceAll(_collapseWhitespace, ' ').trim();

    final parts = cleaned.split(_artistTitleSplit);
    if (parts.length >= 2) {
      final artist = parts.first.trim();
      final title = parts.sublist(1).join(' - ').trim();
      if (artist.isNotEmpty && title.isNotEmpty) {
        return _FilenameGuess(title, artist);
      }
    }
    return _FilenameGuess(cleaned.isEmpty ? nameWithoutExt : cleaned, null);
  }
}
