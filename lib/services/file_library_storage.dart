import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

import 'library_storage.dart';

/// Backend de escritorio (Windows/Linux/macOS): `dart:io` puro en vez de SAF
/// — acá "uri" es simplemente una ruta absoluta de archivo. Ver W1 del plan
/// de escritorio (`heardy-escritorio-windows.md`).
class FileLibraryStorage implements LibraryStorage {
  @override
  Future<LibraryEntry?> pickDirectory() async {
    final path = await FilePicker.platform.getDirectoryPath();
    if (path == null) return null;
    return LibraryEntry(
      uri: path,
      name: p.basename(path),
      isDir: true,
      length: 0,
      lastModified: 0,
    );
  }

  @override
  Future<List<LibraryEntry>> list(String uri) async {
    final entries = <LibraryEntry>[];
    await for (final entity in Directory(uri).list(followLinks: false)) {
      final stat = await entity.stat();
      entries.add(LibraryEntry(
        uri: entity.path,
        name: p.basename(entity.path),
        isDir: entity is Directory,
        length: stat.size,
        lastModified: stat.modified.millisecondsSinceEpoch,
      ));
    }
    return entries;
  }

  @override
  Future<LibraryEntry?> child(String parentUri, String name) async {
    final path = p.join(parentUri, name);
    if (await Directory(path).exists()) {
      final stat = await Directory(path).stat();
      return LibraryEntry(
        uri: path,
        name: name,
        isDir: true,
        length: 0,
        lastModified: stat.modified.millisecondsSinceEpoch,
      );
    }
    if (await File(path).exists()) {
      final stat = await File(path).stat();
      return LibraryEntry(
        uri: path,
        name: name,
        isDir: false,
        length: stat.size,
        lastModified: stat.modified.millisecondsSinceEpoch,
      );
    }
    return null;
  }

  @override
  Future<LibraryEntry> mkdirp(String uri, String name) async {
    final dir = await Directory(p.join(uri, name)).create(recursive: true);
    final stat = await dir.stat();
    return LibraryEntry(
      uri: dir.path,
      name: name,
      isDir: true,
      length: 0,
      lastModified: stat.modified.millisecondsSinceEpoch,
    );
  }

  @override
  Future<bool> exists(String uri, {required bool isDir}) =>
      isDir ? Directory(uri).exists() : File(uri).exists();

  @override
  Future<LibraryEntry?> stat(String uri, {required bool isDir}) async {
    if (!await exists(uri, isDir: isDir)) return null;
    final s = await FileStat.stat(uri);
    return LibraryEntry(
      uri: uri,
      name: p.basename(uri),
      isDir: isDir,
      length: s.size,
      lastModified: s.modified.millisecondsSinceEpoch,
    );
  }

  @override
  Future<void> delete(String uri, {required bool isDir}) =>
      isDir ? Directory(uri).delete(recursive: true) : File(uri).delete();

  /// No existe el concepto de permiso persistido fuera de SAF — si el
  /// archivo está ahí, se puede leer/escribir.
  @override
  Future<bool> hasPersistedPermission(
    String uri, {
    bool checkRead = true,
    bool checkWrite = false,
  }) async =>
      true;

  @override
  Future<Uint8List> readFileBytes(String uri, {int? start, int? count}) async {
    final raf = await File(uri).open();
    try {
      if (start != null) await raf.setPosition(start);
      if (count != null) return await raf.read(count);
      final length = await raf.length();
      final remaining = start == null ? length : length - start;
      return await raf.read(remaining);
    } finally {
      await raf.close();
    }
  }

  @override
  Future<void> copyToLocalFile(String uri, String destPath) async {
    await File(uri).copy(destPath);
  }

  @override
  Future<NewLibraryFile> writeFileBytes(
    String treeUri,
    String fileName,
    String mime,
    Uint8List data, {
    bool overwrite = false,
  }) async {
    await Directory(treeUri).create(recursive: true);
    final path = overwrite ? p.join(treeUri, fileName) : _uniquePath(treeUri, fileName);
    await File(path).writeAsBytes(data, flush: true);
    return NewLibraryFile(uri: path, name: p.basename(path));
  }

  @override
  Future<NewLibraryFile> pasteLocalFile(
    String srcPath,
    String treeUri,
    String fileName,
    String mime,
  ) async {
    await Directory(treeUri).create(recursive: true);
    final path = _uniquePath(treeUri, fileName);
    await File(srcPath).copy(path);
    return NewLibraryFile(uri: path, name: p.basename(path));
  }

  /// Mismo criterio que el proveedor de documentos de Android ante una
  /// colisión de nombre: nunca pisa, prueba " (1)", " (2)"... hasta hallar
  /// uno libre.
  String _uniquePath(String dir, String fileName) {
    var candidate = p.join(dir, fileName);
    if (!File(candidate).existsSync()) return candidate;
    final ext = p.extension(fileName);
    final stem = p.basenameWithoutExtension(fileName);
    var n = 1;
    while (true) {
      candidate = p.join(dir, '$stem ($n)$ext');
      if (!File(candidate).existsSync()) return candidate;
      n++;
    }
  }
}
