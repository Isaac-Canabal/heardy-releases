import 'dart:io';
import 'dart:typed_data';

import 'file_library_storage.dart';
import 'saf_library_storage.dart';

/// Un archivo o carpeta de la biblioteca, tal como lo ve el backend de
/// almacenamiento activo. `uri` es opaco fuera de este backend: en Android es
/// una uri SAF (`content://...`); en escritorio, una ruta absoluta de
/// archivo — ver W1 del plan de escritorio (`heardy-escritorio-windows.md`).
class LibraryEntry {
  final String uri;
  final String name;
  final bool isDir;
  final int length;
  final int lastModified;

  const LibraryEntry({
    required this.uri,
    required this.name,
    required this.isDir,
    required this.length,
    required this.lastModified,
  });
}

/// Resultado de escribir/pegar un archivo nuevo. El nombre final puede
/// diferir del pedido si el backend renombró por una colisión.
class NewLibraryFile {
  final String uri;
  final String name;

  const NewLibraryFile({required this.uri, required this.name});
}

/// Abstracción de almacenamiento de la carpeta de biblioteca del usuario, con
/// dos implementaciones reales: [SafLibraryStorage] (Android, la única hasta
/// ahora) y [FileLibraryStorage] (escritorio, `dart:io`). Mismo patrón que
/// `DownloadSource`/`CloudSource` — ver CLAUDE.md.
///
/// **Regla que no se puede romper**: [readFileBytes] tiene que devolver
/// exactamente los mismos bytes en cualquier backend para el mismo rango de
/// un mismo archivo — `AudioIdentityService` depende de eso para que el
/// mismo audio produzca el mismo hash en el teléfono y en el PC.
abstract class LibraryStorage {
  /// Muestra el selector nativo de carpetas. `null` si el usuario cancela.
  Future<LibraryEntry?> pickDirectory();

  /// Lista el contenido directo de [uri] (no recursivo).
  Future<List<LibraryEntry>> list(String uri);

  /// Busca un hijo directo llamado [name] dentro de [parentUri]. `null` si
  /// no existe.
  Future<LibraryEntry?> child(String parentUri, String name);

  /// Crea (o reutiliza) la carpeta [name] dentro de [uri].
  Future<LibraryEntry> mkdirp(String uri, String name);

  Future<bool> exists(String uri, {required bool isDir});

  /// Como [exists] pero devuelve los metadatos, o `null` si no existe.
  Future<LibraryEntry?> stat(String uri, {required bool isDir});

  Future<void> delete(String uri, {required bool isDir});

  /// En Android, si el permiso persistido de SAF sigue siendo válido. En
  /// escritorio no existe el concepto — siempre `true`.
  Future<bool> hasPersistedPermission(
    String uri, {
    bool checkRead = true,
    bool checkWrite = false,
  });

  /// Lee [count] bytes de [uri] a partir de [start]. Sin ninguno de los dos,
  /// lee el archivo entero.
  Future<Uint8List> readFileBytes(String uri, {int? start, int? count});

  /// Copia [uri] a un archivo local temporal en [destPath].
  Future<void> copyToLocalFile(String uri, String destPath);

  /// Escribe [data] como un archivo nuevo llamado [fileName] dentro de
  /// [treeUri]. Sin `overwrite`, una colisión de nombre se resuelve
  /// renombrando, nunca pisando.
  Future<NewLibraryFile> writeFileBytes(
    String treeUri,
    String fileName,
    String mime,
    Uint8List data, {
    bool overwrite = false,
  });

  /// Copia el archivo local [srcPath] dentro de [treeUri] como [fileName].
  /// Misma resolución de colisión que [writeFileBytes].
  Future<NewLibraryFile> pasteLocalFile(
    String srcPath,
    String treeUri,
    String fileName,
    String mime,
  );
}

/// Sólo para tests. `flutter test` corre siempre como proceso nativo del
/// host (Windows en este repo), así que `Platform.isAndroid` nunca es `true`
/// ahí — ni siquiera cuando el test está ejercitando lógica pensada para
/// Android contra un `SafUtilPlatform`/`SafStreamPlatform` faseado (ver
/// `test/fake_saf.dart`). Sin este hook cada servicio caería en
/// [FileLibraryStorage] durante los tests, sin importar el fake que hayan
/// instalado. El código de la app real nunca llama a esto.
LibraryStorage Function()? _libraryStorageOverrideForTests;

void debugOverrideLibraryStorageForTests(LibraryStorage Function()? factory) {
  _libraryStorageOverrideForTests = factory;
}

/// La implementación real para la plataforma actual — Android sigue con SAF
/// sin ningún cambio de comportamiento; todo lo demás (Windows/Linux/macOS)
/// usa `dart:io`.
LibraryStorage defaultLibraryStorage() =>
    _libraryStorageOverrideForTests?.call() ??
    (Platform.isAndroid ? SafLibraryStorage() : FileLibraryStorage());
