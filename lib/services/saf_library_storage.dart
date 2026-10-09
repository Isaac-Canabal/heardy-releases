import 'dart:typed_data';

import 'package:saf_stream/saf_stream.dart';
import 'package:saf_util/saf_util.dart';
import 'package:saf_util/saf_util_platform_interface.dart';

import 'library_storage.dart';

LibraryEntry _fromSaf(SafDocumentFile f) => LibraryEntry(
      uri: f.uri,
      name: f.name,
      isDir: f.isDir,
      length: f.length,
      lastModified: f.lastModified,
    );

/// Envuelve `saf_util`/`saf_stream` sin cambiar su comportamiento — es
/// literalmente el código que ya existía en cada servicio, movido acá. Los
/// tests siguen faseando `SafUtilPlatform.instance`/`SafStreamPlatform.instance`
/// (ver `test/fake_saf.dart`), así que esta capa es transparente para ellos.
class SafLibraryStorage implements LibraryStorage {
  final SafUtil _safUtil = SafUtil();
  final SafStream _safStream = SafStream();

  @override
  Future<LibraryEntry?> pickDirectory() async {
    final picked = await _safUtil.pickDirectory(
      writePermission: true,
      persistablePermission: true,
    );
    return picked == null ? null : _fromSaf(picked);
  }

  @override
  Future<List<LibraryEntry>> list(String uri) async =>
      (await _safUtil.list(uri)).map(_fromSaf).toList();

  @override
  Future<LibraryEntry?> child(String parentUri, String name) async {
    final child = await _safUtil.child(parentUri, [name]);
    return child == null ? null : _fromSaf(child);
  }

  @override
  Future<LibraryEntry> mkdirp(String uri, String name) async =>
      _fromSaf(await _safUtil.mkdirp(uri, [name]));

  @override
  Future<bool> exists(String uri, {required bool isDir}) =>
      _safUtil.exists(uri, isDir);

  @override
  Future<LibraryEntry?> stat(String uri, {required bool isDir}) async {
    final s = await _safUtil.stat(uri, isDir);
    return s == null ? null : _fromSaf(s);
  }

  @override
  Future<void> delete(String uri, {required bool isDir}) =>
      _safUtil.delete(uri, isDir);

  @override
  Future<bool> hasPersistedPermission(
    String uri, {
    bool checkRead = true,
    bool checkWrite = false,
  }) =>
      _safUtil.hasPersistedPermission(
        uri,
        checkRead: checkRead,
        checkWrite: checkWrite,
      );

  @override
  Future<Uint8List> readFileBytes(String uri, {int? start, int? count}) =>
      _safStream.readFileBytes(uri, start: start, count: count);

  @override
  Future<void> copyToLocalFile(String uri, String destPath) =>
      _safStream.copyToLocalFile(uri, destPath);

  @override
  Future<NewLibraryFile> writeFileBytes(
    String treeUri,
    String fileName,
    String mime,
    Uint8List data, {
    bool overwrite = false,
  }) async {
    final r = await _safStream.writeFileBytes(
      treeUri,
      fileName,
      mime,
      data,
      overwrite: overwrite,
    );
    return NewLibraryFile(uri: r.uri.toString(), name: r.fileName ?? fileName);
  }

  @override
  Future<NewLibraryFile> pasteLocalFile(
    String srcPath,
    String treeUri,
    String fileName,
    String mime,
  ) async {
    final r = await _safStream.pasteLocalFile(srcPath, treeUri, fileName, mime);
    return NewLibraryFile(uri: r.uri.toString(), name: r.fileName ?? fileName);
  }
}
