import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'app_log.dart';
import 'lan_sync_crypto.dart';
import 'secure_token_store.dart';

class LanTrustedPeer {
  final String deviceId;
  final Uint8List publicKey;
  final String label;
  final DateTime pairedAt;

  const LanTrustedPeer({
    required this.deviceId,
    required this.publicKey,
    required this.label,
    required this.pairedAt,
  });

  LanTrustedPeer withLabel(String newLabel) =>
      LanTrustedPeer(deviceId: deviceId, publicKey: publicKey, label: newLabel, pairedAt: pairedAt);

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'publicKey': base64Encode(publicKey),
        'label': label,
        'pairedAt': pairedAt.toUtc().toIso8601String(),
      };

  factory LanTrustedPeer.fromJson(Map<String, dynamic> json) {
    final key = base64Decode(json['publicKey'] as String);
    final id = json['deviceId'] as String;
    if (key.length != lanKeyLength || id.isEmpty) throw const FormatException('par inválido');
    return LanTrustedPeer(
      deviceId: id,
      publicKey: Uint8List.fromList(key),
      label: (json['label'] as String?) ?? '',
      pairedAt: DateTime.tryParse(json['pairedAt'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// El estado existe pero no se pudo leer ahora (bloqueo, permisos, DPAPI):
/// no se toca el archivo ni se crea otra identidad, y se puede reintentar.
class LanTrustStoreUnavailableException implements Exception {
  const LanTrustStoreUnavailableException();

  @override
  String toString() => 'LanTrustStoreUnavailableException';
}

/// Dónde se guarda el estado (identidad + pares de confianza). Nunca se
/// sincroniza, no entra en la carpeta de sync y no se escribe en logs.
abstract class LanStateStorage {
  Future<String?> read();
  Future<void> write(String contents);
}

class MemoryLanStateStorage implements LanStateStorage {
  String? contents;
  @override
  Future<String?> read() async => contents;
  @override
  Future<void> write(String c) async => contents = c;
}

/// Archivo en el directorio privado de la app. En Windows el contenido va
/// cifrado con DPAPI (misma protección que el token de sesión); en Android
/// queda en el almacenamiento privado de la app (`allowBackup=false`).
class FileLanStateStorage implements LanStateStorage {
  static var _tmpCounter = 0;
  final File file;
  final SecureTokenStore? protector;
  FileLanStateStorage(this.file, {this.protector});

  @override
  Future<String?> read() async {
    if (!await file.exists()) return null;
    final raw = await file.readAsString();
    return protector == null ? raw : protector!.unprotect(raw);
  }

  var _chain = Future<void>.value();

  @override
  Future<void> write(String contents) {
    final run = _chain.then((_) => _write(contents));
    _chain = run.catchError((_) {});
    return run;
  }

  Future<void> _write(String contents) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.${_tmpCounter++}.${DateTime.now().microsecondsSinceEpoch}.tmp');
    try {
      await tmp.writeAsString(protector == null ? contents : protector!.protect(contents), flush: true);
      await tmp.rename(file.path);
    } catch (_) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      rethrow;
    }
  }
}

class LanSyncTrustStore {
  final LanStateStorage _storage;
  final RandomBytes _random;
  final String Function() _newId;
  final DateTime Function() _clock;

  late LanSigningKey _identity;
  late String _deviceId;
  final List<LanTrustedPeer> _peers = [];
  var _loaded = false;

  LanSyncTrustStore({
    required LanStateStorage storage,
    RandomBytes? random,
    String Function()? idGenerator,
    DateTime Function()? clock,
  })  : _storage = storage,
        _random = random ?? secureRandomBytes,
        _newId = idGenerator ?? (() => const Uuid().v4()),
        _clock = clock ?? DateTime.now;

  LanSigningKey get identity => _loaded ? _identity : throw StateError('almacén no cargado');
  String get deviceId => _loaded ? _deviceId : throw StateError('almacén no cargado');
  List<LanTrustedPeer> get peers => List.unmodifiable(_peers);

  /// Carga o crea la identidad. Solo un archivo que definitivamente no existe,
  /// o que se leyó bien pero está corrupto, crea una identidad nueva (los pares
  /// hay que emparejarlos otra vez; nunca se reutiliza un estado a medias). Un
  /// error al leer lanza [LanTrustStoreUnavailableException] sin tocar nada.
  Future<void> load() async {
    if (_loaded) return;
    final String? raw;
    try {
      raw = await _storage.read();
    } catch (e) {
      appLog('LanSyncTrustStore: no se pudo leer el estado, no se toca (${e.runtimeType})');
      throw const LanTrustStoreUnavailableException();
    }
    Map<String, dynamic>? state;
    if (raw != null) {
      try {
        state = jsonDecode(raw) as Map<String, dynamic>;
      } catch (e) {
        appLog('LanSyncTrustStore: estado corrupto, se crea una identidad nueva (${e.runtimeType})');
      }
    }
    var created = false;
    try {
      if (state == null) throw const FormatException('sin estado');
      final seed = Uint8List.fromList(base64Decode(state['seed'] as String));
      _identity = await LanSigningKey.fromSeed(seed);
      _deviceId = state['deviceId'] as String;
      if (_deviceId.isEmpty) throw const FormatException('id vacío');
      _peers.clear();
      for (final item in (state['peers'] as List? ?? const [])) {
        try {
          _peers.add(LanTrustedPeer.fromJson(Map<String, dynamic>.from(item as Map)));
        } catch (_) {
          appLog('LanSyncTrustStore: se omite un par ilegible');
        }
      }
    } catch (_) {
      _identity = await LanSigningKey.fromSeed(_random(lanKeyLength));
      _deviceId = _newId();
      _peers.clear();
      created = true;
    }
    _loaded = true;
    if (created) await _persist();
  }

  Future<void> _persistQueue = Future<void>.value();

  /// Una escritura a la vez; cada una guarda el estado vigente cuando le toca.
  Future<void> _persist() {
    final run = _persistQueue.then((_) => _storage.write(jsonEncode({
          'v': 1,
          'deviceId': _deviceId,
          'seed': base64Encode(_identity.seed),
          'peers': [for (final peer in _peers) peer.toJson()],
        })));
    _persistQueue = run.catchError((_) {});
    return run;
  }

  LanTrustedPeer? byDeviceId(String id) {
    for (final peer in _peers) {
      if (peer.deviceId == id) return peer;
    }
    return null;
  }

  /// Confía solo si clave Y id coinciden con un par guardado.
  bool isTrusted(Uint8List publicKey, String deviceId) {
    final peer = byDeviceId(deviceId);
    if (peer == null || peer.publicKey.length != publicKey.length) return false;
    var diff = 0;
    for (var i = 0; i < publicKey.length; i++) {
      diff |= peer.publicKey[i] ^ publicKey[i];
    }
    return diff == 0;
  }

  /// Guarda o actualiza (mismo id) un par tras un emparejado confirmado.
  Future<void> addPeer({required String deviceId, required Uint8List publicKey, required String label}) async {
    _peers.removeWhere((peer) => peer.deviceId == deviceId || _sameKey(peer.publicKey, publicKey));
    _peers.add(LanTrustedPeer(deviceId: deviceId, publicKey: publicKey, label: label, pairedAt: _clock()));
    await _persist();
  }

  Future<void> removePeer(String deviceId) async {
    _peers.removeWhere((peer) => peer.deviceId == deviceId);
    await _persist();
  }

  static bool _sameKey(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

Future<LanSyncTrustStore> openDefaultLanTrustStore() async {
  final dir = await getApplicationSupportDirectory();
  final store = LanSyncTrustStore(
    storage: FileLanStateStorage(
      File(p.join(dir.path, 'lan_sync_state.bin')),
      protector: defaultSecureTokenStore(),
    ),
  );
  await store.load();
  return store;
}
