import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/song.dart';
import 'audio_identity.dart';
import 'cover_art.dart';
import 'database_helper.dart';
import 'download_source.dart';
import 'library_storage.dart';
import 'lyrics_service.dart';
import 'mp4_chunk_offset_fix.dart';
import 'storage_service.dart';
import 'app_log.dart';

/// Qué pasó con una descarga, para que la UI diga algo útil.
enum DownloadOutcome {
  /// Canción nueva: archivo escrito y fila creada.
  inserted,

  /// Ya estaba en la biblioteca (mismo hash de audio). No se duplicaron
  /// bytes; solo se añadió a la playlist destino si faltaba.
  alreadyInLibrary,
}

class DownloadResult {
  final DownloadOutcome outcome;
  final Song song;

  /// La pista tal como se usó de verdad: la resuelta si hubo `resolveFirst`,
  /// la de entrada si no.
  final RemoteTrack track;

  const DownloadResult(this.outcome, this.song, this.track);
}

/// Convierte una pista remota en una canción de la biblioteca local.
///
/// El invariante que gobierna todo este archivo: **tras una descarga, el
/// siguiente escaneo debe clasificar el archivo como `unchanged`**, nunca
/// como `inserted` ni `moved`. Por eso la identidad se calcula con
/// [AudioIdentityService] —el mismo código que usa el scanner— leyendo por
/// SAF el archivo ya pegado, y por eso `fileSize`/`modifiedAt` se leen con
/// `stat()` DESPUÉS de pegar y no se asumen. Ver CLAUDE.md DD2/DD3.
class DownloadService {
  final DownloadSource _source;
  final StorageService _storage;
  final DatabaseHelper _db;
  final LibraryStorage _libraryStorage;
  final AudioIdentityService _identity;
  final http.Client Function() _clientFactory;

  DownloadService({
    required DownloadSource source,
    StorageService? storage,
    DatabaseHelper? db,
    LibraryStorage? libraryStorage,
    http.Client Function()? clientFactory,
  })  : _source = source,
        _storage = storage ?? StorageService(),
        _db = db ?? DatabaseHelper.instance,
        _libraryStorage = libraryStorage ?? defaultLibraryStorage(),
        _identity = AudioIdentityService(),
        _clientFactory = clientFactory ?? (() => http.Client());

  /// Descarga [track] y la incorpora a la biblioteca, dentro de la carpeta de
  /// [playlistId] si se indica (si no, cae en la bandeja como cualquier
  /// archivo suelto).
  ///
  /// [resolveFirst] pide la metadata definitiva antes de bajar nada. Hay que
  /// ponerlo a true siempre que [track] venga de `/search` o de expandir una
  /// playlist, porque ahí `artist` es el nombre del canal y no el artista
  /// real — y como los tags se escriben dentro del archivo, ese error
  /// sobrevive a un reescaneo.
  ///
  /// **El paso vive aquí y no en quien llama a propósito**: así ningún call
  /// site futuro puede saltárselo. Si el resolve falla, falla la descarga
  /// entera; nunca se continúa con metadata plana como respaldo.
  ///
  /// [onResolved] se dispara en cuanto el resolve tiene éxito, antes de bajar
  /// un solo byte, para que la cola pueda persistirlo: si la descarga falla y
  /// el trabajo se reintenta, el resolve ya no se repite.
  Future<DownloadResult> download(
    RemoteTrack track, {
    String? playlistId,
    bool resolveFirst = false,
    Future<void> Function(RemoteTrack resolved)? onResolved,
    ProgressCallback? onProgress,
    CancellationCheck? isCancelled,
  }) async {
    final rootUri = await _storage.getLibraryRootUri();
    if (rootUri == null) {
      throw const DownloadSourceException(
        DownloadSourceErrorKind.notConfigured,
        'Elige primero una carpeta de biblioteca en Ajustes',
      );
    }
    // Android revoca el permiso SAF de la carpeta al desinstalar la app —
    // siempre, incondicionalmente — pero la uri guardada puede sobrevivir a
    // una reinstalación si el Auto Backup de Android restauró
    // SharedPreferences (activado por defecto, ver MusicProvider.
    // refreshLibraryRootUri). Sin este chequeo, `resolvePlaylistFolder`/
    // `pasteLocalFile` más abajo lanzarían un SecurityException crudo que
    // la cola trataría como un error de extracción reintentable — inútil
    // para algo que ningún reintento (ni una búsqueda de reemplazo) puede
    // arreglar; hace falta volver a elegir la carpeta en Ajustes.
    if (!await _storage.hasValidPermission(rootUri)) {
      throw const DownloadSourceException(
        DownloadSourceErrorKind.notConfigured,
        'El permiso de la carpeta de biblioteca ya no es válido. Elige la carpeta de nuevo en Ajustes.',
      );
    }

    if (resolveFirst) {
      _throwIfCancelled(isCancelled);
      final source = track.sourceUrl.isNotEmpty
          ? track.sourceUrl
          : 'https://www.youtube.com/watch?v=${track.id}';
      // Sin try/catch: un fallo aquí debe propagarse tal cual, con su
      // DownloadSourceErrorKind intacto, para que la cola distinga entre
      // reintentar (red, IP bloqueada) y descartar (vídeo borrado).
      track = await _source.resolve(source);
      await onResolved?.call(track);
    }

    final tempDir = await getTemporaryDirectory();
    final tempPath = '${tempDir.path}/heardy_dl_${_sanitizeId(track.id)}.m4a';
    final tempFile = File(tempPath);

    try {
      // 1. Bytes.
      await _source.fetchAudio(
        track.id,
        tempPath,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
      _throwIfCancelled(isCancelled);

      // 2. Carátula, antes de escribir tags para poder empotrarla.
      final coverBytes = await _fetchCoverArt(track.thumbnailUrl, track.id);

      // 3. Tags dentro del archivo. Esto es lo que hace que el archivo sea
      // autodescriptivo en disco: si el usuario lo copia a otro reproductor,
      // o si un día borra la base de datos y reescanea, la metadata
      // sobrevive porque vive en el propio contenedor, no solo en SQLite.
      await _writeTags(tempFile, track, coverBytes);
      _throwIfCancelled(isCancelled);

      // 4. Carpeta destino.
      final String folderUri;
      final String? playlistName;
      if (playlistId != null) {
        final playlist = await _db.getPlaylistById(playlistId);
        playlistName = playlist?.name;
        folderUri = playlist == null
            ? rootUri
            : await _storage.resolvePlaylistFolder(rootUri, playlist.name);
      } else {
        playlistName = null;
        folderUri = rootUri;
      }

      // 5-6. Pegar. Se usa SIEMPRE la uri devuelta: ante una colisión de
      // nombre el proveedor de documentos renombra por su cuenta, así que
      // reconstruirla a mano daría una uri que no existe.
      final fileName = _fileNameFor(track);
      final newFile = await _libraryStorage.pasteLocalFile(
        tempPath,
        folderUri,
        fileName,
        'audio/mp4',
      );
      final newUri = newFile.uri;

      // 7. Tamaño y mtime reales, tal como los verá el scanner. Después de
      // pegar, nunca antes: la mtime la fija el proveedor de documentos.
      final stat = await _libraryStorage.stat(newUri, isDir: false);
      if (stat == null) {
        throw const DownloadSourceException(
          DownloadSourceErrorKind.extraction,
          'El archivo se escribió pero no se pudo leer de vuelta',
        );
      }

      // 8. Identidad, con el mismo código que el scanner.
      final identity = await _identity.compute(
        uri: newUri,
        length: stat.length,
        ext: 'm4a',
        debugName: fileName,
      );

      // 9. ¿Ya la teníamos? Mismo audio = misma canción, aunque venga de otra
      // URL. Se borra el archivo recién pegado en vez de duplicar bytes: una
      // canción puede estar en varias playlists sin estar dos veces en disco.
      final existing = await _db.getSongByHash(identity.hash);
      if (existing != null) {
        try {
          await _libraryStorage.delete(newUri, isDir: false);
        } catch (e) {
          appLog('DownloadService: no se pudo borrar el duplicado $newUri: $e');
        }
        if (playlistId != null) {
          await _addToPlaylist(playlistId, existing.id);
        }
        if (track.sourceUrl.isNotEmpty) {
          await _db.fillSongSourceUrlIfEmpty(existing.id, track.sourceUrl);
        }
        // La fila ya existía pero sin carátula (descargas anteriores a que
        // las miniaturas llegaran en JPEG): ésta es la ocasión de dársela.
        if (coverBytes != null && !await _hasArtwork(existing)) {
          final artPath = await saveCoverArt(existing.id, coverBytes);
          if (artPath.isNotEmpty) await _db.updateSongArtPath(existing.id, artPath);
        }
        return DownloadResult(DownloadOutcome.alreadyInLibrary, existing, track);
      }

      // 10. Carátula en el directorio privado, misma convención que
      // MetadataService._saveArtwork: un archivo por canción, nunca un blob.
      final artPath = coverBytes == null ? '' : await saveCoverArt(identity.hash, coverBytes);

      final song = Song(
        id: identity.hash,
        title: track.title,
        artist: track.artist,
        duration: track.durationSeconds,
        filePath: '',
        artPath: artPath,
        format: 'm4a',
        downloadDate: DateTime.now(),
        uri: newUri,
        fileHash: identity.hash,
        hashKind: identity.kind,
        fileSize: stat.length,
        modifiedAt: stat.lastModified,
        album: track.album ?? playlistName,
        sourceUrl: track.sourceUrl.isEmpty ? null : track.sourceUrl,
      );
      await _db.insertSong(song);
      if (playlistId != null) {
        await _addToPlaylist(playlistId, song.id);
      }

      // 12. Letras por adelantado, para que "ahora sonando" las tenga listas.
      // Nunca fatal: una descarga correcta no se convierte en fallida porque
      // LRCLIB esté caído.
      try {
        await LyricsService.instance.getLyrics(
          songId: song.id,
          title: song.title,
          artist: song.artist,
          durationSeconds: song.duration,
        );
      } catch (e) {
        appLog('DownloadService: no se pudieron precargar letras de ${song.title}: $e');
      }

      return DownloadResult(DownloadOutcome.inserted, song, track);
    } finally {
      // 11. El temporal no sobrevive a esta llamada pase lo que pase — mismo
      // patrón que MetadataService.extract.
      try {
        if (await tempFile.exists()) await tempFile.delete();
      } catch (_) {}
    }
  }

  Future<void> _addToPlaylist(String playlistId, String songId) async {
    if (await _db.isSongInPlaylist(playlistId, songId)) return;
    final maxOrder = await _db.getMaxOrderForPlaylist(playlistId) ?? -1;
    await _db.addSongToPlaylist(playlistId, songId, maxOrder + 1);
  }

  void _throwIfCancelled(CancellationCheck? isCancelled) {
    if (isCancelled?.call() ?? false) {
      throw const DownloadSourceException(
        DownloadSourceErrorKind.cancelled,
        'Descarga cancelada',
      );
    }
  }

  Future<Uint8List?> _fetchCoverArt(String url, String videoId) async {
    if (coverArtCandidates(url, videoId).isEmpty) return null;
    final client = _clientFactory();
    try {
      return await fetchCoverArt(client, url, videoId);
    } finally {
      client.close();
    }
  }

  Future<bool> _hasArtwork(Song song) async =>
      song.artPath.isNotEmpty && await File(song.artPath).exists();

  Future<void> _writeTags(File file, RemoteTrack track, Uint8List? cover) async {
    try {
      // `audio_metadata_reader` reescribe moov/ilst sin recalcular stco, así
      // que hay que guardar el archivo tal cual antes de tocarlo para poder
      // calcular cuánto se desplazó mdat después — ver mp4_chunk_offset_fix.dart.
      final originalBytes = file.readAsBytesSync();

      updateMetadata(file, (metadata) {
        metadata.setTitle(track.title);
        metadata.setArtist(track.artist);
        if (track.album != null) metadata.setAlbum(track.album!);
        if (cover != null) {
          metadata.setPictures([
            Picture(cover, mimeForImage(cover), PictureType.coverFront),
          ]);
        }
      });

      repairMp4ChunkOffsetsAfterTagWrite(file, originalBytes);
    } catch (e) {
      // No fatal: la metadata sigue viviendo en la fila de `songs`. Solo se
      // pierde la propiedad de que el archivo se describa a sí mismo.
      appLog('DownloadService: no se pudieron escribir tags en ${file.path}: $e');
    }
  }


  /// "Artista - Título.m4a", legible desde un explorador de archivos, porque
  /// estos archivos son del usuario y va a verlos.
  String _fileNameFor(RemoteTrack track) {
    final artist = _sanitizeSegment(track.artist);
    final title = _sanitizeSegment(track.title);
    final stem = artist.isEmpty ? title : '$artist - $title';
    final safeStem = stem.isEmpty ? _sanitizeId(track.id) : stem;
    // 120 caracteres deja margen bajo el límite de 255 bytes de la mayoría de
    // sistemas de archivos incluso con acentos en UTF-8.
    final clipped = safeStem.length > 120 ? safeStem.substring(0, 120).trim() : safeStem;
    return '$clipped.m4a';
  }

  String _sanitizeSegment(String value) {
    return value
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .replaceAll(RegExp(r'\.+$'), '')
        .trim();
  }

  String _sanitizeId(String id) {
    final safe = id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
    return safe.isEmpty ? 'pista' : safe;
  }
}
