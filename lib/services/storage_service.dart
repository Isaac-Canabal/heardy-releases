import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import 'library_storage.dart';
import 'app_log.dart';

/// Acceso a la carpeta de música local elegida por el usuario, vía
/// [LibraryStorage] — SAF en Android (CLAUDE.md D1), `dart:io` en escritorio
/// (W1 del plan de escritorio).
///
/// Owns the whole lifecycle of the library root: picking it, recognizing an
/// already-initialized one so re-picking never nests `Heardy/` inside
/// itself, and clearing it when it turns out to be gone.
class StorageService {
  static const String libraryFolderName = 'Heardy';
  static const String _rootMarkerFileName = '.heardy_root';
  static const String _libraryRootUriKey = 'heardy_library_root_uri';

  final LibraryStorage _storage;

  StorageService({LibraryStorage? storage}) : _storage = storage ?? defaultLibraryStorage();

  Future<String?> getLibraryRootUri() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_libraryRootUriKey);
  }

  /// Forgets the stored root — e.g. after a scan discovers it's gone.
  Future<void> clearLibraryRootUri() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_libraryRootUriKey);
  }

  /// Shows the system folder picker and resolves it to a library root.
  /// Returns null if the user cancelled.
  ///
  /// Three cases, so re-picking never nests `Heardy/` inside itself:
  /// - the chosen folder already has the root marker (any name) -> use it
  ///   as-is;
  /// - it doesn't, but it's literally named "Heardy" (a root from before
  ///   this marker existed, or the user pointed straight at a folder with
  ///   that name) -> use it as-is and write the marker retroactively;
  /// - otherwise -> create/reuse a "Heardy" child of the chosen folder
  ///   (looked up first, never blindly `mkdirp`'d, so re-picking the same
  ///   parent doesn't create a second one either) and mark that.
  Future<String?> pickLibraryRoot() async {
    final picked = await _storage.pickDirectory();
    if (picked == null) return null;

    final String rootUri;
    if (await _hasRootMarker(picked.uri)) {
      rootUri = picked.uri;
    } else if (picked.name.toLowerCase() == libraryFolderName.toLowerCase()) {
      rootUri = picked.uri;
      await _writeRootMarker(rootUri);
    } else {
      final existingChild = await _findChildDir(picked.uri, libraryFolderName);
      if (existingChild != null) {
        rootUri = existingChild.uri;
        if (!await _hasRootMarker(rootUri)) {
          await _writeRootMarker(rootUri);
        }
      } else {
        final created = await _storage.mkdirp(picked.uri, libraryFolderName);
        rootUri = created.uri;
        await _writeRootMarker(rootUri);
      }
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_libraryRootUriKey, rootUri);
    return rootUri;
  }

  Future<bool> hasValidPermission(String uri) {
    return _storage.hasPersistedPermission(uri, checkRead: true, checkWrite: true);
  }

  /// Carpeta de una playlist dentro de la raíz, creándola si no existe.
  ///
  /// Es el único punto donde la app crea algo en la carpeta del usuario, y lo
  /// hace por la enmienda a D3 (ver CLAUDE.md, DD3): crear archivos nuevos en
  /// la carpeta que el usuario eligió para su música es el mecanismo de
  /// importación. Lo que sigue prohibido es reorganizar o reescribir lo que
  /// ya estaba ahí.
  ///
  /// Se busca con `child()` antes de `mkdirp()`, misma cautela que
  /// [pickLibraryRoot], para no acabar con dos carpetas del mismo nombre.
  Future<String> resolvePlaylistFolder(String rootUri, String playlistName) async {
    final safeName = sanitizeFolderName(playlistName);
    final existing = await _findChildDir(rootUri, safeName);
    if (existing != null) return existing.uri;
    final created = await _storage.mkdirp(rootUri, safeName);
    return created.uri;
  }

  /// Quita lo que ningún sistema de archivos de Android acepta en un nombre.
  /// Nunca devuelve vacío: un nombre de playlist compuesto solo de caracteres
  /// prohibidos crearía una carpeta sin nombre.
  static String sanitizeFolderName(String name) {
    final cleaned = name
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        // Un punto final lo descarta FAT32, común en tarjetas SD.
        .replaceAll(RegExp(r'\.+$'), '')
        .trim();
    if (cleaned.isEmpty) return 'Sin nombre';
    return cleaned.length > 100 ? cleaned.substring(0, 100).trim() : cleaned;
  }

  /// Borra la carpeta de una playlist, sólo si existe y quedó vacía.
  ///
  /// Nunca borra una carpeta con contenido: podría tener un archivo suelto
  /// que el usuario metió ahí a mano, o el archivo físico de una canción que
  /// sigue viva en otra playlist — mover una canción entre playlists nunca
  /// mueve el archivo (CLAUDE.md, "Playlists viven en SQLite"), así que su
  /// carpeta de origen puede seguir teniendo contenido válido aunque la
  /// playlist que la creó ya no exista.
  ///
  /// Busca la carpeta por el nombre *actual* de la playlist, igual que
  /// [resolvePlaylistFolder] — si la playlist fue renombrada después de
  /// crearse, la carpeta física original nunca se renombró (mismo principio
  /// de solo-importación), así que puede no encontrarse aquí. Se queda como
  /// residuo, igual que ya pasa hoy con cualquier subcarpeta de una playlist
  /// renombrada; no es una regresión de este método.
  Future<void> deletePlaylistFolderIfEmpty(String rootUri, String playlistName) async {
    try {
      final folder = await _findChildDir(rootUri, sanitizeFolderName(playlistName));
      if (folder == null) return;
      final children = await _storage.list(folder.uri);
      if (children.isNotEmpty) return;
      await _storage.delete(folder.uri, isDir: true);
    } catch (e) {
      appLog('StorageService: no se pudo borrar la carpeta de "$playlistName": $e');
    }
  }

  Future<List<LibraryEntry>> listChildren(String uri) => _storage.list(uri);

  /// Suma el tamaño real de todo lo que hay en la carpeta de biblioteca: los
  /// archivos sueltos en la raíz (a la espera de asignación en la Bandeja)
  /// más el contenido de cada subcarpeta de playlist. No baja más de un
  /// nivel — la propia estructura que la app gestiona (`Heardy/<Playlist>/`)
  /// no tiene más, y [LibraryScanService] tampoco soporta subcarpetas
  /// anidadas, así que esto no debería contarlas de todas formas.
  ///
  /// `dart:io` no puede leer esta carpeta (D1): es `content://`, no un path
  /// de archivo. Por eso Ajustes no puede simplemente sumar `File(...).length()`
  /// como hacía antes de la migración a SAF — eso sólo veía las descargas
  /// heredadas en almacenamiento privado, nunca lo que realmente ocupa
  /// espacio hoy.
  Future<int> calculateLibrarySize(String rootUri) async {
    var total = 0;
    try {
      final rootChildren = await _storage.list(rootUri);
      for (final entry in rootChildren) {
        if (entry.isDir) {
          try {
            final children = await _storage.list(entry.uri);
            for (final child in children) {
              if (!child.isDir && child.length > 0) total += child.length;
            }
          } catch (_) {}
        } else if (entry.length > 0) {
          total += entry.length;
        }
      }
    } catch (e) {
      appLog('StorageService: no se pudo calcular el tamaño de $rootUri: $e');
    }
    return total;
  }

  Future<LibraryEntry?> _findChildDir(String parentUri, String name) async {
    try {
      final child = await _storage.child(parentUri, name);
      return (child != null && child.isDir) ? child : null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _hasRootMarker(String folderUri) async {
    try {
      final marker = await _storage.child(folderUri, _rootMarkerFileName);
      return marker != null;
    } catch (_) {
      return false;
    }
  }

  Future<void> _writeRootMarker(String folderUri) async {
    try {
      await _storage.writeFileBytes(
        folderUri,
        _rootMarkerFileName,
        'text/plain',
        Uint8List(0),
        overwrite: true,
      );
    } catch (e) {
      appLog('StorageService: no se pudo escribir el marcador de raíz en $folderUri: $e');
    }
  }
}
