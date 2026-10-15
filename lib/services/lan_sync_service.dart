import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'app_log.dart';
import 'folder_sync_format.dart';
import 'folder_sync_service.dart';
import 'lan_sync_crypto.dart';
import 'lan_sync_discovery.dart';
import 'lan_sync_protocol.dart';
import 'lan_sync_trust_store.dart';

/// Qué se intercambia: el mismo snapshot schema 2 de la sincronización por
/// carpeta. La implementación real envuelve [FolderSyncService].
abstract class LanPayloadHost {
  Future<Uint8List> buildPayload();
  Future<LanApplyReport> applyPayload(Uint8List bytes);
}

class LanApplyReport {
  final int playlistsAdded;
  final int membershipsAdded;
  final int historyAdded;
  const LanApplyReport({this.playlistsAdded = 0, this.membershipsAdded = 0, this.historyAdded = 0});
}

class FolderSnapshotPayloadHost implements LanPayloadHost {
  final FolderSyncService _service;
  FolderSnapshotPayloadHost(this._service);

  @override
  Future<Uint8List> buildPayload() async => encodeSnapshot(await _service.buildSnapshot());

  @override
  Future<LanApplyReport> applyPayload(Uint8List bytes) async {
    final report = await _service.applyRemoteSnapshot(parseSnapshot(bytes));
    return LanApplyReport(
      playlistsAdded: report.playlistsAdded,
      membershipsAdded: report.membershipsAdded,
      historyAdded: report.historyAdded,
    );
  }
}

enum LanSyncOutcome {
  ok,
  paired,
  unreachable,
  timeout,
  peerClosed,
  untrustedPeer,
  peerNotPairing,
  sasRejectedLocal,
  sasRejectedPeer,
  protocolError,
  tooLarge,
  notLocalAddress,
  busy,
  rateLimited,
  noNetwork,
  failed,
}

enum LanPhase { idle, connecting, handshaking, confirming, exchanging, applying }

class LanSyncResult {
  final LanSyncOutcome outcome;
  final LanPeerInfo? peer;
  final LanApplyReport? applied;
  const LanSyncResult(this.outcome, {this.peer, this.applied});

  bool get isSuccess => outcome == LanSyncOutcome.ok || outcome == LanSyncOutcome.paired;
}

class LanSasRequest {
  final String sas;
  final LanPeerInfo peer;
  final bool incoming;

  /// Ya había un dispositivo de confianza con este id pero con otra clave:
  /// aceptar sustituye su clave.
  final bool replacesTrustedKey;

  const LanSasRequest({
    required this.sas,
    required this.peer,
    required this.incoming,
    this.replacesTrustedKey = false,
  });
}

typedef LanSasPrompt = Future<bool> Function(LanSasRequest request);

class LanSyncConfig {
  final int preferredPort;
  final Future<List<InternetAddress>> Function() listenAddresses;
  final int maxConnections;
  final Duration handshakeTimeout;
  final Duration preAuthTimeout;
  final Duration pairingBackoffBase;
  final Duration pairingBackoffMax;
  final Duration frameTimeout;
  final Duration connectTimeout;
  final Duration confirmTimeout;
  final Duration sessionDeadline;

  const LanSyncConfig({
    this.preferredPort = lanDefaultTcpPort,
    this.listenAddresses = privateIPv4Addresses,
    this.maxConnections = 2,
    this.handshakeTimeout = const Duration(seconds: 15),
    this.preAuthTimeout = const Duration(seconds: 5),
    this.pairingBackoffBase = const Duration(seconds: 3),
    this.pairingBackoffMax = const Duration(minutes: 5),
    this.frameTimeout = const Duration(seconds: 30),
    this.connectTimeout = const Duration(seconds: 6),
    this.confirmTimeout = const Duration(seconds: 130),
    this.sessionDeadline = const Duration(minutes: 8),
  });
}

class LanNoNetworkException implements Exception {
  const LanNoNetworkException();
}

/// [LanFrameIo] sobre un socket TCP: `u32 longitud | cuerpo`, con tope de
/// tamaño antes de reservar memoria y tiempo máximo en cada lectura.
class SocketFrameIo implements LanFrameIo {
  final Socket _socket;
  late final StreamIterator<Uint8List> _it = StreamIterator(_socket);
  var _buf = Uint8List(0);

  SocketFrameIo(this._socket);

  @override
  Future<void> write(Uint8List body) async {
    try {
      _socket.add(frameWithHeader(body));
      await _socket.flush();
    } on SocketException {
      throw const LanProtocolException(LanFailure.closed);
    }
  }

  Future<Uint8List> _take(int n, Stopwatch clock, Duration timeout) async {
    while (_buf.length < n) {
      final remaining = timeout - clock.elapsed;
      if (remaining <= Duration.zero) throw const LanProtocolException(LanFailure.timeout);
      final bool more;
      try {
        more = await _it.moveNext().timeout(remaining, onTimeout: () => throw const LanProtocolException(LanFailure.timeout));
      } on SocketException {
        throw const LanProtocolException(LanFailure.closed);
      }
      if (!more) throw const LanProtocolException(LanFailure.closed);
      final chunk = _it.current;
      final merged = Uint8List(_buf.length + chunk.length)
        ..setRange(0, _buf.length, _buf)
        ..setRange(_buf.length, _buf.length + chunk.length, chunk);
      _buf = merged;
    }
    final out = Uint8List.sublistView(_buf, 0, n);
    _buf = Uint8List.sublistView(_buf, n);
    return Uint8List.fromList(out);
  }

  @override
  Future<Uint8List> read({required Duration timeout, required int maxBytes}) async {
    final clock = Stopwatch()..start();
    final header = await _take(4, clock, timeout);
    final length = ByteData.sublistView(header).getUint32(0, Endian.big);
    if (length == 0) throw const LanProtocolException(LanFailure.malformed);
    if (length > maxBytes) throw const LanProtocolException(LanFailure.frameTooLarge);
    return _take(length, clock, timeout);
  }

  Future<void> close() async {
    try {
      await _it.cancel();
    } catch (_) {}
    _socket.destroy();
  }
}

LanSyncOutcome _outcomeFor(LanFailure f) {
  switch (f) {
    case LanFailure.timeout:
      return LanSyncOutcome.timeout;
    case LanFailure.closed:
      return LanSyncOutcome.peerClosed;
    case LanFailure.untrusted:
    case LanFailure.wrongPeer:
      return LanSyncOutcome.untrustedPeer;
    case LanFailure.notPairing:
      return LanSyncOutcome.peerNotPairing;
    case LanFailure.peerAborted:
      return LanSyncOutcome.sasRejectedPeer;
    case LanFailure.payloadTooLarge:
    case LanFailure.frameTooLarge:
      return LanSyncOutcome.tooLarge;
    default:
      return LanSyncOutcome.protocolError;
  }
}

class LanSyncService {
  final LanSyncTrustStore trust;
  final LanPayloadHost host;
  final LanSyncConfig config;
  final RandomBytes _random;
  final LanPairingGate gate;
  final String label;

  LanSasPrompt? sasPrompt;
  void Function(LanPhase phase)? onPhase;
  void Function(LanSyncResult result)? onIncomingResult;

  final List<ServerSocket> _servers = [];
  final Set<Socket> _sockets = {};
  final Set<String> _preAuthIps = {};
  final Map<Socket, String> _livePeers = {};
  final DateTime Function() _clock;
  var _active = 0;
  var _outgoingPairing = false;
  var _pairingFailures = 0;
  DateTime? _pairingBackoffUntil;
  var _applyChain = Future<void>.value();
  int? _port;

  LanSyncService({
    required this.trust,
    required this.host,
    required this.label,
    LanSyncConfig? config,
    RandomBytes? random,
    LanPairingGate? gate,
    DateTime Function()? clock,
  })  : config = config ?? const LanSyncConfig(),
        _clock = clock ?? DateTime.now,
        _random = random ?? secureRandomBytes,
        gate = gate ?? LanPairingGate();

  int? get port => _port;
  bool get isListening => _servers.isNotEmpty;

  // Servidor ----------------------------------------------------------------

  /// Escucha solo en las direcciones de red local indicadas por la
  /// configuración (nunca 0.0.0.0). Devuelve el puerto TCP realmente usado.
  Future<int> startServer() async {
    if (_servers.isNotEmpty) return _port!;
    final addrs = await config.listenAddresses();
    var port = config.preferredPort;
    for (final addr in addrs) {
      ServerSocket? server;
      try {
        server = await ServerSocket.bind(addr, port);
      } on SocketException {
        if (_servers.isEmpty) {
          try {
            server = await ServerSocket.bind(addr, 0);
          } on SocketException {
            server = null;
          }
        }
      }
      if (server == null) continue;
      port = server.port;
      _servers.add(server);
      server.listen(_onConnection, onError: (_) {});
    }
    if (_servers.isEmpty) throw const LanNoNetworkException();
    _port = port;
    return port;
  }

  Future<void> stopServer() async {
    final servers = List.of(_servers);
    _servers.clear();
    _port = null;
    for (final s in servers) {
      await s.close();
    }
    for (final s in List.of(_sockets)) {
      s.destroy();
    }
    _sockets.clear();
    gate.close();
  }

  /// Corta las sesiones en curso con ese dispositivo (al olvidarlo).
  void terminateSessionsOf(String deviceId) {
    for (final e in _livePeers.entries.toList()) {
      if (e.value == deviceId) e.key.destroy();
    }
  }

  void _onConnection(Socket socket) {
    final ip = socket.remoteAddress.address;
    if (!isLocalNetworkAddress(socket.remoteAddress) || _active >= config.maxConnections || _preAuthIps.contains(ip)) {
      socket.destroy();
      return;
    }
    _active++;
    _sockets.add(socket);
    _preAuthIps.add(ip);
    var released = false;
    void releasePreAuth() {
      if (released) return;
      released = true;
      _preAuthIps.remove(ip);
    }

    unawaited(_serve(socket, releasePreAuth).whenComplete(() {
      releasePreAuth();
      _active--;
      _sockets.remove(socket);
      _livePeers.remove(socket);
    }));
  }

  Duration _left(Stopwatch clock) {
    final left = config.handshakeTimeout - clock.elapsed;
    if (left <= Duration.zero) throw const LanProtocolException(LanFailure.timeout);
    return left;
  }

  Future<void> _serve(Socket socket, void Function() releasePreAuth) async {
    final io = SocketFrameIo(socket);
    final deadline = Timer(config.sessionDeadline, socket.destroy);
    final handshakeClock = Stopwatch()..start();
    var attempting = false;
    var succeeded = false;
    LanMode mode = LanMode.session;
    LanHandshake? hs;
    try {
      final m1 = await io.read(
        timeout: config.preAuthTimeout < _left(handshakeClock) ? config.preAuthTimeout : _left(handshakeClock),
        maxBytes: lanMaxHandshakeBytes,
      );
      // El hueco se toma al contestar M1 en modo emparejado: desde ahí cualquier
      // conexión que no termine emparejando cuenta como fallo, aunque se corte
      // antes de M3 (si no, un intermediario reciclaría conexiones gratis
      // buscando una SAS favorable).
      attempting = !_outgoingPairing && gate.tryBeginAttempt();
      hs = LanHandshake.responder(
        identity: trust.identity,
        deviceId: trust.deviceId,
        label: label,
        isTrusted: trust.isTrusted,
        random: _random,
        pairingAvailable: attempting,
      );
      await io.write(await hs.onM1(m1));
      final m3 = await io.read(timeout: _left(handshakeClock), maxBytes: lanMaxHandshakeBytes);
      await hs.onM3(m3);
      mode = hs.effectiveMode;
      if (mode == LanMode.session && attempting) {
        gate.endAttempt();
        attempting = false;
      }
      await hs.onAuth(await io.read(timeout: _left(handshakeClock), maxBytes: lanMaxFrameBytes));
      await io.write(await hs.authFrame());
      _livePeers[socket] = hs.peer!.deviceId;
      releasePreAuth();
      final channel = hs.channel;
      if (mode == LanMode.pairing) {
        final result = await _confirmPairing(io, hs, incoming: true);
        succeeded = result.isSuccess;
        if (succeeded) gate.registerSuccess();
        onIncomingResult?.call(result);
      } else {
        final theirs = await receiveMessage(io, channel, timeout: config.frameTimeout);
        final ours = await host.buildPayload();
        final applied = await _apply(theirs);
        await sendMessage(io, channel, ours);
        final bye = await receiveFrame(io, channel, timeout: config.frameTimeout);
        if (bye.type != lanFrameBye) throw const LanProtocolException(LanFailure.unexpectedFrame);
        succeeded = true;
        onIncomingResult?.call(LanSyncResult(LanSyncOutcome.ok, peer: hs.peer, applied: applied));
      }
    } on LanProtocolException catch (e) {
      appLog('LanSyncService: conexión entrante cerrada (${e.failure.name})');
    } catch (e) {
      appLog('LanSyncService: conexión entrante fallida (${e.runtimeType})');
    } finally {
      deadline.cancel();
      if (attempting) {
        gate.endAttempt();
        if (!succeeded) gate.registerFailure();
      }
      await io.close();
    }
  }

  Future<LanApplyReport> _apply(Uint8List bytes) {
    final completer = Completer<LanApplyReport>();
    _applyChain = _applyChain.then((_) async {
      try {
        onPhase?.call(LanPhase.applying);
        completer.complete(await host.applyPayload(bytes));
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  // Emparejado ---------------------------------------------------------------

  Future<LanSyncResult> _confirmPairing(SocketFrameIo io, LanHandshake hs, {required bool incoming}) async {
    final peer = hs.peer!;
    final channel = hs.channel;
    onPhase?.call(LanPhase.confirming);
    final prompt = sasPrompt;
    var accepted = false;
    if (prompt != null) {
      final known = trust.byDeviceId(peer.deviceId);
      final replaces = known != null && !trust.isTrusted(peer.publicKey, peer.deviceId);
      try {
        accepted = await prompt(LanSasRequest(sas: hs.sas, peer: peer, incoming: incoming, replacesTrustedKey: replaces))
            .timeout(config.confirmTimeout, onTimeout: () => false);
      } catch (_) {
        accepted = false;
      }
    }
    if (!accepted) {
      try {
        await sendFrame(io, channel, lanFrameAbort);
      } catch (_) {}
      return LanSyncResult(LanSyncOutcome.sasRejectedLocal, peer: peer);
    }
    await sendFrame(io, channel, lanFrameConfirm);
    final frame = await receiveFrame(io, channel, timeout: config.confirmTimeout);
    if (frame.type == lanFrameAbort) return LanSyncResult(LanSyncOutcome.sasRejectedPeer, peer: peer);
    if (frame.type != lanFrameConfirm) throw const LanProtocolException(LanFailure.unexpectedFrame);
    await trust.addPeer(deviceId: peer.deviceId, publicKey: peer.publicKey, label: peer.label);
    return LanSyncResult(LanSyncOutcome.paired, peer: peer);
  }

  // Cliente ------------------------------------------------------------------

  /// Conecta, autentica y ejecuta el emparejado ([LanMode.pairing]) o la
  /// sincronización ([LanMode.session]). Nunca lanza: devuelve el resultado.
  Future<LanSyncResult> connect({
    required InternetAddress address,
    required int port,
    required LanMode mode,
    String? expectedDeviceId,
  }) async {
    if (mode == LanMode.session) {
      return _connect(address: address, port: port, mode: mode, expectedDeviceId: expectedDeviceId);
    }
    final until = _pairingBackoffUntil;
    if (until != null && _clock().isBefore(until)) return const LanSyncResult(LanSyncOutcome.rateLimited);
    if (_outgoingPairing || gate.attemptActive) return const LanSyncResult(LanSyncOutcome.busy);
    _outgoingPairing = true;
    LanSyncResult result;
    try {
      result = await _connect(address: address, port: port, mode: mode, expectedDeviceId: expectedDeviceId);
    } finally {
      _outgoingPairing = false;
    }
    switch (result.outcome) {
      case LanSyncOutcome.paired:
        _pairingFailures = 0;
        _pairingBackoffUntil = null;
      case LanSyncOutcome.unreachable || LanSyncOutcome.notLocalAddress:
        break;
      default:
        _pairingFailures++;
        final factor = 1 << (_pairingFailures - 1).clamp(0, 20);
        final wait = config.pairingBackoffBase * factor;
        _pairingBackoffUntil = _clock().add(wait < config.pairingBackoffMax ? wait : config.pairingBackoffMax);
    }
    return result;
  }

  Future<LanSyncResult> _connect({
    required InternetAddress address,
    required int port,
    required LanMode mode,
    String? expectedDeviceId,
  }) async {
    if (!isLocalNetworkAddress(address)) return const LanSyncResult(LanSyncOutcome.notLocalAddress);
    if (port < 1 || port > 65535) return const LanSyncResult(LanSyncOutcome.notLocalAddress);
    onPhase?.call(LanPhase.connecting);
    Socket socket;
    try {
      socket = await Socket.connect(address, port, timeout: config.connectTimeout);
    } on SocketException {
      return const LanSyncResult(LanSyncOutcome.unreachable);
    } on TimeoutException {
      return const LanSyncResult(LanSyncOutcome.unreachable);
    }
    socket.setOption(SocketOption.tcpNoDelay, true);
    final io = SocketFrameIo(socket);
    final deadline = Timer(config.sessionDeadline, socket.destroy);
    final handshakeClock = Stopwatch()..start();
    LanPeerInfo? peer;
    try {
      onPhase?.call(LanPhase.handshaking);
      final hs = LanHandshake.initiator(
        mode: mode,
        identity: trust.identity,
        deviceId: trust.deviceId,
        label: label,
        isTrusted: trust.isTrusted,
        random: _random,
        expectedPeerDeviceId: expectedDeviceId,
      );
      await io.write(await hs.start());
      final m2 = await io.read(timeout: _left(handshakeClock), maxBytes: lanMaxHandshakeBytes);
      await io.write(await hs.onM2(m2));
      await io.write(await hs.authFrame());
      await hs.onAuth(await io.read(timeout: _left(handshakeClock), maxBytes: lanMaxFrameBytes));
      peer = hs.peer;
      _livePeers[socket] = peer!.deviceId;
      final channel = hs.channel;
      if (mode == LanMode.pairing) return await _confirmPairing(io, hs, incoming: false);
      onPhase?.call(LanPhase.exchanging);
      await sendMessage(io, channel, await host.buildPayload());
      final theirs = await receiveMessage(io, channel, timeout: config.frameTimeout);
      final applied = await _apply(theirs);
      await sendFrame(io, channel, lanFrameBye);
      return LanSyncResult(LanSyncOutcome.ok, peer: peer, applied: applied);
    } on LanProtocolException catch (e) {
      appLog('LanSyncService: sesión saliente cerrada (${e.failure.name})');
      return LanSyncResult(_outcomeFor(e.failure), peer: peer);
    } on SocketException {
      return LanSyncResult(LanSyncOutcome.peerClosed, peer: peer);
    } catch (e) {
      appLog('LanSyncService: sesión saliente fallida (${e.runtimeType})');
      return LanSyncResult(LanSyncOutcome.failed, peer: peer);
    } finally {
      deadline.cancel();
      _livePeers.remove(socket);
      await io.close();
      onPhase?.call(LanPhase.idle);
    }
  }
}
