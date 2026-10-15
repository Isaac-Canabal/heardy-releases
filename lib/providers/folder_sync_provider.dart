import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../services/app_log.dart';
import '../services/database_helper.dart';
import '../services/folder_sync_service.dart';
import '../services/library_storage.dart';

enum FolderSyncOutcome { none, ok, noLibraryFolder, failed }

/// Sincronización/backup por carpeta (`.heardy/` dentro de la biblioteca).
/// Manual: nada la dispara sola. Independiente de [SyncProvider] (servidor);
/// se pueden usar los dos o cualquiera.
class FolderSyncProvider with ChangeNotifier {
  final String? Function() _libraryRoot;
  final LibraryStorage Function() _storage;
  final DatabaseHelper _db;
  final Future<void> Function()? _onImported;
  final String Function() _newId;

  static const _prefsDeviceId = 'folder_sync_device_id';
  static const _prefsLastHash = 'folder_sync_last_hash';
  static const _prefsLastAt = 'folder_sync_last_at';

  FolderSyncProvider({
    required String? Function() libraryRoot,
    LibraryStorage Function()? storage,
    DatabaseHelper? db,
    Future<void> Function()? onImported,
    String Function()? idGenerator,
  })  : _libraryRoot = libraryRoot,
        _storage = storage ?? defaultLibraryStorage,
        _db = db ?? DatabaseHelper.instance,
        _onImported = onImported,
        _newId = idGenerator ?? (() => const Uuid().v4());

  bool _busy = false;
  FolderSyncOutcome _outcome = FolderSyncOutcome.none;
  FolderSyncReport? _lastReport;
  DateTime? _lastSyncAt;
  List<Map<String, dynamic>> _otherDeviceSongs = const [];
  List<LibraryEntry> _backups = const [];

  bool get isBusy => _busy;
  FolderSyncOutcome get outcome => _outcome;
  FolderSyncReport? get lastReport => _lastReport;
  DateTime? get lastSyncAt => _lastSyncAt;
  List<Map<String, dynamic>> get otherDeviceSongs => _otherDeviceSongs;
  List<LibraryEntry> get backups => _backups;

  Future<FolderSyncService> _service() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_prefsDeviceId);
    if (id == null || id.isEmpty) {
      id = _newId();
      await prefs.setString(_prefsDeviceId, id);
    }
    return FolderSyncService(
      storage: _storage(),
      db: _db,
      deviceId: id,
      deviceLabel: Platform.operatingSystem,
    );
  }

  Future<void> _run(Future<FolderSyncReport> Function(FolderSyncService service, String root) body) async {
    if (_busy) return;
    final root = _libraryRoot();
    if (root == null) {
      _outcome = FolderSyncOutcome.noLibraryFolder;
      notifyListeners();
      return;
    }
    _busy = true;
    notifyListeners();
    try {
      final service = await _service();
      final report = await body(service, root);
      _lastReport = report;
      _outcome = report.importError == null ? FolderSyncOutcome.ok : FolderSyncOutcome.failed;
      if (report.contentHash.isNotEmpty) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_prefsLastHash, report.contentHash);
        _lastSyncAt = DateTime.now();
        await prefs.setInt(_prefsLastAt, _lastSyncAt!.millisecondsSinceEpoch);
      }
      if (report.playlistsAdded + report.membershipsAdded + report.historyAdded > 0) {
        await _onImported?.call();
      }
      _otherDeviceSongs = await service.otherDeviceSongs(root);
      _backups = await service.listBackups(root);
    } catch (e) {
      appLog('FolderSyncProvider: falló la sincronización por carpeta (${e.runtimeType})');
      _outcome = FolderSyncOutcome.failed;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> syncNow() => _run((service, root) async {
        final prefs = await SharedPreferences.getInstance();
        return service.sync(root, lastExportedHash: prefs.getString(_prefsLastHash));
      });

  Future<void> restoreBackup(LibraryEntry backup) => _run((service, root) => service.restoreBackup(backup));

  /// Solo lectura: canciones de otros dispositivos y backups disponibles.
  Future<void> refresh() async {
    final root = _libraryRoot();
    if (root == null) return;
    try {
      final service = await _service();
      final prefs = await SharedPreferences.getInstance();
      final at = prefs.getInt(_prefsLastAt);
      if (at != null) _lastSyncAt = DateTime.fromMillisecondsSinceEpoch(at);
      _otherDeviceSongs = await service.otherDeviceSongs(root);
      _backups = await service.listBackups(root);
    } catch (e) {
      appLog('FolderSyncProvider: no se pudo leer la carpeta (${e.runtimeType})');
    }
    notifyListeners();
  }
}
