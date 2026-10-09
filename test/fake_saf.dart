// Shared in-memory fake of the SAF plugin surface, so scan/identity/download
// logic can be exercised under `flutter test` with no Android device.
//
// The services under test instantiate `SafUtil()`/`SafStream()` directly, so
// there is no DI seam — tests substitute at the *platform interface* level:
//
//     SafUtilPlatform.instance   = FakeSafUtil(backend);
//     SafStreamPlatform.instance = FakeSafStream(backend);
//
// Both fakes `extend` the abstract platform class rather than implementing it,
// which is what lets `PlatformInterface.verifyToken` pass.
import 'dart:io';
import 'dart:typed_data';

import 'package:saf_stream/saf_stream_platform_interface.dart';
import 'package:saf_util/saf_util_platform_interface.dart';

class FakeDir {
  final String uri;
  final String name;
  final List<String> childUris = [];
  FakeDir(this.uri, this.name);
}

class FakeFile {
  final String uri;
  final String name;
  Uint8List bytes;
  int mtime;
  FakeFile(this.uri, this.name, this.bytes, this.mtime);
}

class FakeSafBackend {
  final Map<String, FakeDir> dirs = {};
  final Map<String, FakeFile> files = {};
  final Set<String> deletedUris = {};
  // Uris para las que hasPersistedPermission debe simular que Android ya
  // revocó el grant (p. ej. tras una desinstalación) — el resto se
  // comporta como si el permiso siguiera vigente, que es lo que todo el
  // resto de esta suite ya asumía antes de que este chequeo existiera.
  final Set<String> revokedPermissionUris = {};
  // Static, not per-instance: several tests each create their own backend but
  // share the one real sqflite_common_ffi database, so uris must stay unique
  // across backends too, or a fresh test's file can collide with a leftover
  // row from an earlier test and get reconciled as an update to someone else's
  // song instead of an insert.
  static int _counter = 0;

  String _newUri() => 'fake://node${_counter++}';

  FakeDir addDir(FakeDir? parent, String name) {
    final dir = FakeDir(_newUri(), name);
    dirs[dir.uri] = dir;
    parent?.childUris.add(dir.uri);
    return dir;
  }

  FakeFile addFile(FakeDir parent, String name, Uint8List bytes, int mtime) {
    final file = FakeFile(_newUri(), name, bytes, mtime);
    files[file.uri] = file;
    parent.childUris.add(file.uri);
    return file;
  }

  void unlink(FakeDir parent, String uri) => parent.childUris.remove(uri);
  void relink(FakeDir parent, String uri) => parent.childUris.add(uri);

  /// Simulates the folder being deleted (or its volume unmounted, or its
  /// permission revoked) from outside the app: any further `list()` on this
  /// uri throws, like a real SAF provider would on a stale document uri.
  void markDeleted(String uri) => deletedUris.add(uri);

  /// The directory a file currently lives in, or null if it's unlinked.
  FakeDir? parentOf(String fileUri) {
    for (final dir in dirs.values) {
      if (dir.childUris.contains(fileUri)) return dir;
    }
    return null;
  }

  FakeFile? childFileNamed(FakeDir dir, String name) {
    for (final childUri in dir.childUris) {
      final f = files[childUri];
      if (f != null && f.name == name) return f;
    }
    return null;
  }
}

class FakeSafUtil extends SafUtilPlatform {
  final FakeSafBackend backend;
  FakeSafUtil(this.backend);

  /// Set before calling code that triggers `pickDirectory` (there's no real
  /// system picker under `flutter test`), to simulate what the user chose.
  SafDocumentFile? nextPick;

  SafDocumentFile _docOf(String uri) {
    final d = backend.dirs[uri];
    if (d != null) {
      return SafDocumentFile(uri: d.uri, name: d.name, isDir: true, length: 0, lastModified: 0);
    }
    final f = backend.files[uri]!;
    return SafDocumentFile(uri: f.uri, name: f.name, isDir: false, length: f.bytes.length, lastModified: f.mtime);
  }

  @override
  Future<SafDocumentFile?> pickDirectory({
    String? initialUri,
    bool? writePermission,
    bool? persistablePermission,
  }) async {
    return nextPick;
  }

  @override
  Future<List<SafDocumentFile>> list(String uri) async {
    if (backend.deletedUris.contains(uri)) {
      throw StateError('fake FileNotFoundException: $uri no longer exists');
    }
    final dir = backend.dirs[uri];
    if (dir == null) return [];
    return dir.childUris.map(_docOf).toList();
  }

  @override
  Future<bool> hasPersistedPermission(
    String uri, {
    bool checkRead = true,
    bool checkWrite = false,
  }) async {
    return !backend.revokedPermissionUris.contains(uri);
  }

  @override
  Future<bool> exists(String uri, bool isDir) async {
    if (backend.deletedUris.contains(uri)) return false;
    return backend.dirs.containsKey(uri) || backend.files.containsKey(uri);
  }

  @override
  Future<SafDocumentFile?> stat(String uri, bool? isDir, {bool? throws}) async {
    if (backend.deletedUris.contains(uri)) return null;
    if (!backend.dirs.containsKey(uri) && !backend.files.containsKey(uri)) return null;
    return _docOf(uri);
  }

  @override
  Future<void> delete(String uri, bool isDir) async {
    final parent = backend.parentOf(uri);
    if (parent != null) parent.childUris.remove(uri);
    backend.files.remove(uri);
    backend.dirs.remove(uri);
  }

  @override
  Future<SafDocumentFile?> child(String uri, List<String> names) async {
    if (names.isEmpty) return null;
    final dir = backend.dirs[uri];
    if (dir == null) return null;
    for (final childUri in dir.childUris) {
      final d = backend.dirs[childUri];
      if (d != null && d.name == names.first) {
        return SafDocumentFile(uri: d.uri, name: d.name, isDir: true, length: 0, lastModified: 0);
      }
      final f = backend.files[childUri];
      if (f != null && f.name == names.first) {
        return SafDocumentFile(uri: f.uri, name: f.name, isDir: false, length: f.bytes.length, lastModified: f.mtime);
      }
    }
    return null;
  }

  @override
  Future<SafDocumentFile> mkdirp(String uri, List<String> names) async {
    var parentUri = uri;
    SafDocumentFile? created;
    for (final name in names) {
      final existing = await child(parentUri, [name]);
      if (existing != null) {
        parentUri = existing.uri;
        created = existing;
        continue;
      }
      final parentDir = backend.dirs[parentUri]!;
      final newDir = backend.addDir(parentDir, name);
      parentUri = newDir.uri;
      created = SafDocumentFile(uri: newDir.uri, name: newDir.name, isDir: true, length: 0, lastModified: 0);
    }
    return created!;
  }
}

class FakeSafStream extends SafStreamPlatform {
  final FakeSafBackend backend;
  FakeSafStream(this.backend);

  /// Monotonically increasing stand-in for the document provider's clock, so
  /// a pasted file gets an mtime the caller did not choose — mirroring the
  /// real provider, which is why production code must `stat()` *after* a
  /// paste rather than assuming what it wrote.
  static int _clock = 900000;

  @override
  Future<Uint8List> readFileBytes(String uri, {int? start, int? count}) async {
    final file = backend.files[uri];
    if (file == null) throw StateError('no such fake file: $uri');
    final s = start ?? 0;
    final end = count == null ? file.bytes.length : (s + count).clamp(0, file.bytes.length);
    return Uint8List.sublistView(file.bytes, s.clamp(0, file.bytes.length), end);
  }

  @override
  Future<void> copyToLocalFile(String srcUri, String destPath) async {
    final file = backend.files[srcUri];
    if (file == null) throw StateError('no such fake file: $srcUri');
    await File(destPath).writeAsBytes(file.bytes);
  }

  @override
  Future<SafNewFile> writeFileBytes(
    String treeUri,
    String fileName,
    String mime,
    Uint8List data, {
    bool? overwrite,
    bool? append,
  }) async {
    final dir = backend.dirs[treeUri];
    if (dir == null) throw StateError('no such fake dir: $treeUri');
    final existing = backend.childFileNamed(dir, fileName);
    if (existing != null) {
      existing.bytes = data;
      return SafNewFile(Uri.parse(existing.uri), existing.name);
    }
    final file = backend.addFile(dir, fileName, data, _clock++);
    return SafNewFile(Uri.parse(file.uri), file.name);
  }

  @override
  Future<SafNewFile> pasteLocalFile(
    String srcPath,
    String treeUri,
    String fileName,
    String mime, {
    bool? overwrite,
    bool? append,
  }) async {
    final dir = backend.dirs[treeUri];
    if (dir == null) throw StateError('no such fake dir: $treeUri');
    final bytes = await File(srcPath).readAsBytes();

    if (overwrite == true) {
      final existing = backend.childFileNamed(dir, fileName);
      if (existing != null) {
        existing.bytes = bytes;
        existing.mtime = _clock++;
        return SafNewFile(Uri.parse(existing.uri), existing.name);
      }
    }

    // Real SAF disambiguates a name collision itself rather than failing,
    // which is exactly why callers must use the returned uri/name and never
    // reconstruct them from what they asked for.
    var finalName = fileName;
    var suffix = 1;
    while (backend.childFileNamed(dir, finalName) != null) {
      final dot = fileName.lastIndexOf('.');
      final stem = dot == -1 ? fileName : fileName.substring(0, dot);
      final ext = dot == -1 ? '' : fileName.substring(dot);
      finalName = '$stem ($suffix)$ext';
      suffix++;
    }

    final file = backend.addFile(dir, finalName, bytes, _clock++);
    return SafNewFile(Uri.parse(file.uri), file.name);
  }
}
