import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../services/app_log.dart';
import '../services/folder_sync_service.dart';
import '../services/lan_sync_discovery.dart';
import '../services/lan_sync_protocol.dart';
import '../services/lan_sync_service.dart';
import '../services/lan_sync_trust_store.dart';

typedef ParsedLanAddress = ({InternetAddress address, int port});

/// `192.168.1.20` o `192.168.1.20:53418`. Solo IPv4 literal: nunca se resuelve
/// un nombre, y quien llama además exige que sea una dirección de red local.
ParsedLanAddress? parseLanAddress(String input, {int defaultPort = lanDefaultTcpPort}) {
  final text = input.trim();
  if (text.isEmpty || text.length > 21) return null;
  final parts = text.split(':');
  if (parts.length > 2) return null;
  final octets = parts[0].split('.');
  if (octets.length != 4) return null;
  for (final o in octets) {
    if (!RegExp(r'^\d{1,3}$').hasMatch(o) || int.parse(o) > 255) return null;
  }
  var port = defaultPort;
  if (parts.length == 2) {
    if (!RegExp(r'^\d{1,5}$').hasMatch(parts[1])) return null;
    port = int.parse(parts[1]);
    if (port < 1 || port > 65535) return null;
  }
  return (address: InternetAddress(parts[0]), port: port);
}

const _multicastChannel = MethodChannel('heardy/multicast_lock');

/// Descubrimiento y servidor de la sincronización por Wi-Fi. Solo existen
/// mientras la pantalla está abierta ([start] / [stop]); nada corre en segundo
/// plano.
class LanSyncProvider with ChangeNotifier {
  final Future<LanSyncTrustStore> Function() _openTrust;
  final FolderSyncService Function(String deviceId, String label) _folderService;
  final Future<void> Function()? _onImported;
  final LanSyncConfig _config;
  final LanDiscoveryTransport Function(LanSyncProvider self)? _transportFactory;

  LanSyncProvider({
    required FolderSyncService Function(String deviceId, String label) folderService,
    Future<LanSyncTrustStore> Function()? openTrust,
    Future<void> Function()? onImported,
    LanSyncConfig? config,
    LanDiscoveryTransport Function(LanSyncProvider self)? transportFactory,
  })  : _folderService = folderService,
        _openTrust = openTrust ?? openDefaultLanTrustStore,
        _onImported = onImported,
        _config = config ?? const LanSyncConfig(),
        _transportFactory = transportFactory;

  LanSyncTrustStore? _trust;
  LanSyncService? _service;
  LanSyncDiscovery? _discovery;
  Timer? _pairingTimer;
  Timer? _refreshTimer;
  Completer<bool>? _sasCompleter;

  var _active = false;
  var _starting = false;
  var _busy = false;
  var _noNetwork = false;
  var _storeUnavailable = false;
  LanPhase _phase = LanPhase.idle;
  LanSyncResult? _lastResult;
  LanSasRequest? _pendingSas;
  String? _addressHint;

  bool get isActive => _active;
  bool get isBusy => _busy;
  bool get noNetwork => _noNetwork;
  bool get storeUnavailable => _storeUnavailable;
  LanPhase get phase => _phase;
  LanSyncResult? get lastResult => _lastResult;
  LanSasRequest? get pendingSas => _pendingSas;
  String? get addressHint => _addressHint;
  int? get port => _service?.port;
  List<LanTrustedPeer> get peers => _trust?.peers ?? const [];
  List<LanNearbyDevice> get nearby => _discovery?.devices ?? const [];
  DateTime? get pairingOpenUntil => _service?.gate.openUntil;
  bool get pairingCoolingDown => _service?.gate.coolingDown ?? false;

  String _label(String deviceId) {
    final os = Platform.isAndroid
        ? 'Android'
        : Platform.isWindows
            ? 'Windows'
            : Platform.operatingSystem;
    return '$os ${deviceId.substring(0, deviceId.length < 4 ? deviceId.length : 4)}';
  }

  /// Abre el servidor y el descubrimiento. Si no hay red local queda
  /// [noNetwork] y nada escucha.
  Future<void> start() async {
    if (_active || _starting) return;
    _starting = true;
    _noNetwork = false;
    _storeUnavailable = false;
    _lastResult = null;
    notifyListeners();
    try {
      final trust = _trust ??= await _openTrust();
      final label = _label(trust.deviceId);
      final service = LanSyncService(
        trust: trust,
        host: FolderSnapshotPayloadHost(_folderService(trust.deviceId, label)),
        label: label,
        config: _config,
      );
      service.sasPrompt = _askSas;
      service.onPhase = (p) {
        _phase = p;
        notifyListeners();
      };
      service.onIncomingResult = _onIncoming;
      final port = await service.startServer();
      _service = service;
      _addressHint = await _bestAddress(port);
      final transport = _transportFactory?.call(this) ??
          UdpDiscoveryTransport(
            acquireMulticastLock: Platform.isAndroid ? () => _multicastChannel.invokeMethod<void>('acquire') : null,
            releaseMulticastLock: Platform.isAndroid ? () => _multicastChannel.invokeMethod<void>('release') : null,
          );
      final discovery = LanSyncDiscovery(transport: transport, onChanged: notifyListeners);
      _discovery = discovery;
      await discovery.start(LanAnnouncement(deviceId: trust.deviceId, label: label, port: port));
      _active = true;
      _refreshTimer = Timer.periodic(const Duration(seconds: 2), (_) => notifyListeners());
    } on LanNoNetworkException {
      _noNetwork = true;
      await _teardown();
    } on LanTrustStoreUnavailableException {
      _storeUnavailable = true;
      await _teardown();
    } catch (e) {
      appLog('LanSyncProvider: no se pudo iniciar (${e.runtimeType})');
      _noNetwork = true;
      await _teardown();
    } finally {
      _starting = false;
      notifyListeners();
    }
  }

  Future<String?> _bestAddress(int port) async {
    final addrs = await privateIPv4Addresses();
    return addrs.isEmpty ? null : '${addrs.first.address}:$port';
  }

  Future<void> _teardown() async {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _pairingTimer?.cancel();
    _pairingTimer = null;
    _active = false;
    if (_sasCompleter != null && !_sasCompleter!.isCompleted) _sasCompleter!.complete(false);
    _sasCompleter = null;
    _pendingSas = null;
    try {
      await _discovery?.stop();
    } catch (e) {
      appLog('LanSyncProvider: error al parar el descubrimiento (${e.runtimeType})');
    }
    _discovery = null;
    try {
      await _service?.stopServer();
    } catch (e) {
      appLog('LanSyncProvider: error al parar el servidor (${e.runtimeType})');
    }
    _service = null;
    _addressHint = null;
  }

  Future<void> stop() async {
    await _teardown();
    notifyListeners();
  }

  // Emparejado y sincronización ------------------------------------------------

  void openPairingWindow() {
    final service = _service;
    if (service == null) return;
    service.gate.open();
    _pairingTimer?.cancel();
    final until = service.gate.openUntil;
    if (until != null) {
      _pairingTimer = Timer(until.difference(DateTime.now()) + const Duration(milliseconds: 200), notifyListeners);
    }
    notifyListeners();
  }

  void closePairingWindow() {
    _service?.gate.close();
    notifyListeners();
  }

  @visibleForTesting
  Future<bool> askSasForTest(LanSasRequest request) => _askSas(request);

  /// Un solo código a la vez: si ya hay uno esperando respuesta, el nuevo se
  /// rechaza en vez de reemplazarlo (si no, la respuesta del usuario al primer
  /// diálogo se aplicaría al segundo).
  Future<bool> _askSas(LanSasRequest request) {
    if (_sasCompleter != null) return Future.value(false);
    final completer = Completer<bool>();
    _sasCompleter = completer;
    _pendingSas = request;
    notifyListeners();
    return completer.future.timeout(_config.confirmTimeout, onTimeout: () {
      if (identical(_sasCompleter, completer)) {
        _pendingSas = null;
        _sasCompleter = null;
        notifyListeners();
      }
      return false;
    });
  }

  /// Respuesta del usuario al diálogo de la SAS de [request]; se ignora si ya
  /// no es la solicitud vigente.
  void answerSas(LanSasRequest request, bool matches) {
    if (!identical(request, _pendingSas)) return;
    final completer = _sasCompleter;
    _pendingSas = null;
    _sasCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete(matches);
    notifyListeners();
  }

  Future<void> _onIncoming(LanSyncResult result) async {
    _lastResult = result;
    if (result.outcome == LanSyncOutcome.paired) _service?.gate.close();
    await _notifyImported(result);
    notifyListeners();
  }

  Future<void> _notifyImported(LanSyncResult result) async {
    final a = result.applied;
    if (a != null && a.playlistsAdded + a.membershipsAdded + a.historyAdded > 0) {
      try {
        await _onImported?.call();
      } catch (e) {
        appLog('LanSyncProvider: falló el refresco tras importar (${e.runtimeType})');
      }
    }
  }

  Future<void> _run(InternetAddress address, int port, LanMode mode, {String? expectedDeviceId}) async {
    final service = _service;
    if (service == null || _busy) return;
    _busy = true;
    _lastResult = null;
    notifyListeners();
    try {
      final result = await service.connect(
        address: address,
        port: port,
        mode: mode,
        expectedDeviceId: expectedDeviceId,
      );
      _lastResult = result;
      await _notifyImported(result);
    } finally {
      _busy = false;
      _phase = LanPhase.idle;
      notifyListeners();
    }
  }

  Future<void> pairWithNearby(LanNearbyDevice device) => _run(device.address, device.port, LanMode.pairing);

  Future<void> syncWithPeer(LanTrustedPeer peer) async {
    final device = nearby.where((d) => d.deviceId == peer.deviceId).firstOrNull;
    if (device == null) {
      _lastResult = const LanSyncResult(LanSyncOutcome.unreachable);
      notifyListeners();
      return;
    }
    await _run(device.address, device.port, LanMode.session, expectedDeviceId: peer.deviceId);
  }

  Future<void> syncWithAddress(ParsedLanAddress target) =>
      _run(target.address, target.port, LanMode.session);

  Future<void> pairWithAddress(ParsedLanAddress target) =>
      _run(target.address, target.port, LanMode.pairing);

  Future<void> forget(String deviceId) async {
    await _trust?.removePeer(deviceId);
    _service?.terminateSessionsOf(deviceId);
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_teardown());
    super.dispose();
  }
}
