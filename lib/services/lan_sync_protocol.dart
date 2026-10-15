/// Protocolo de la sincronización por Wi-Fi (sin dart:io ni Flutter, para poder
/// razonarlo y probarlo de forma determinista).
///
/// Mensajes (cada uno es una trama `u32 longitud | cuerpo`):
///   M1 I->R  0x01 | C            C = SHA-256("heardy-lan/1 commit" | mI)
///   M2 R->I  0x02 | mR           R revela su parte (nunca antes de ver C)
///   M3 I->R  0x03 | mI           I revela; R comprueba que SHA-256(...|mI) == C
///   M4 I->R  AEAD(0x04 | firmaI) firmaI = Ed25519(idI, "heardy-lan/1 auth I" | th)
///   M5 R->I  AEAD(0x05 | firmaR) firmaR = Ed25519(idR, "heardy-lan/1 auth R" | th)
/// mI = ver | modo | epkI | nonceI | idPubI | deviceIdI | etiquetaI
/// mR = ver | modo | epkR | nonceR | idPubR | deviceIdR | etiquetaR
/// th = SHA-256("heardy-lan/1" | u16 |mI| | mI | u16 |mR| | mR)
///
/// Compromiso y revelación: ninguna de las dos partes puede elegir su aporte
/// después de ver el de la otra, así que un intermediario no puede ajustar las
/// dos transcripciones para que la SAS (8 dígitos de SHA-256("...sas" | th))
/// coincida en ambos lados; acierta con probabilidad 1e-8 por intento y los
/// intentos fallidos de emparejar tienen límite.
///
/// Claves: dh = X25519(efímera propia, efímera ajena);
/// k_i2r / k_r2i = HKDF-SHA256(ikm = dh, sal = th, info = "heardy-lan/1 i2r|r2i").
/// Desde M4 todo va con ChaCha20-Poly1305, una clave por sentido y nonce =
/// contador de 64 bits implícito (un reenvío, descarte o reordenamiento falla
/// al autenticar). AAD = longitud de la trama.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show SecretBoxAuthenticationError;

import 'lan_sync_crypto.dart';

const lanProtocolVersion = 1;
const lanMaxHandshakeBytes = 512;
const lanChunkBytes = 128 * 1024;
const lanMaxFrameBytes = lanChunkBytes + 64;
const lanMaxPayloadBytes = 10 * 1024 * 1024;
const lanMaxTextBytes = 64;
const lanLabelMaxRunes = 40;

const _tM1 = 0x01, _tM2 = 0x02, _tM3 = 0x03;
const lanFrameAuth = 0x04;
const lanFrameConfirm = 0x06;
const lanFrameAbort = 0x07;
const lanFrameData = 0x20;
const lanFrameEnd = 0x21;
const lanFrameBye = 0x2F;

enum LanMode {
  session(0),
  pairing(1);

  final int wire;
  const LanMode(this.wire);
}

enum LanFailure {
  malformed,
  unsupportedVersion,
  notPairing,
  untrusted,
  wrongPeer,
  badSignature,
  commitmentMismatch,
  decrypt,
  frameTooLarge,
  payloadTooLarge,
  unexpectedFrame,
  timeout,
  closed,
  peerAborted,
}

class LanProtocolException implements Exception {
  final LanFailure failure;
  const LanProtocolException(this.failure);

  @override
  String toString() => 'LanProtocolException(${failure.name})';
}

class LanPeerInfo {
  final Uint8List publicKey;
  final String deviceId;
  final String label;
  const LanPeerInfo({required this.publicKey, required this.deviceId, required this.label});
}

typedef LanTrustCheck = bool Function(Uint8List publicKey, String deviceId);

/// Transporte de tramas ya delimitadas. La implementación con sockets vive en
/// `lan_sync_service.dart`; las pruebas usan tuberías en memoria.
abstract class LanFrameIo {
  Future<void> write(Uint8List body);

  /// Lee una trama completa; lanza [LanProtocolException] por tamaño,
  /// tiempo agotado o cierre.
  Future<Uint8List> read({required Duration timeout, required int maxBytes});
}

Uint8List frameWithHeader(Uint8List body) {
  final out = Uint8List(4 + body.length);
  ByteData.sublistView(out).setUint32(0, body.length, Endian.big);
  out.setRange(4, out.length, body);
  return out;
}

class _Writer {
  final BytesBuilder _b = BytesBuilder(copy: false);
  _Writer u8(int v) {
    _b.addByte(v);
    return this;
  }

  _Writer u16(int v) {
    _b.add([(v >> 8) & 0xFF, v & 0xFF]);
    return this;
  }

  _Writer raw(List<int> v) {
    _b.add(v);
    return this;
  }

  _Writer text(String s) {
    final bytes = utf8.encode(s);
    if (bytes.length > lanMaxTextBytes) throw const LanProtocolException(LanFailure.malformed);
    return u8(bytes.length).raw(bytes);
  }

  Uint8List done() => _b.toBytes();
}

class _Reader {
  final Uint8List _d;
  int _i = 0;
  _Reader(this._d);

  Uint8List raw(int n) {
    if (n < 0 || _i + n > _d.length) throw const LanProtocolException(LanFailure.malformed);
    final out = Uint8List.sublistView(_d, _i, _i + n);
    _i += n;
    return out;
  }

  int u8() => raw(1)[0];

  String text() {
    final n = u8();
    if (n > lanMaxTextBytes) throw const LanProtocolException(LanFailure.malformed);
    try {
      return utf8.decode(raw(n));
    } on FormatException {
      throw const LanProtocolException(LanFailure.malformed);
    }
  }

  void expectEnd() {
    if (_i != _d.length) throw const LanProtocolException(LanFailure.malformed);
  }
}

String sanitizeLanLabel(String raw) {
  final cleaned = raw
      .replaceAll(RegExp(r'[\u200B-\u200F\u202A-\u202E\u2060\u2066-\u2069\uFEFF]'), '')
      .replaceAll(RegExp(r'[\u0000-\u001F\u007F-\u009F]'), ' ')
      .trim();
  final runes = cleaned.runes.toList();
  return String.fromCharCodes(runes.length > lanLabelMaxRunes ? runes.sublist(0, lanLabelMaxRunes) : runes);
}

class _Hello {
  final int version;
  final int mode;
  final Uint8List epk;
  final Uint8List nonce;
  final Uint8List idPub;
  final String deviceId;
  final String label;
  final Uint8List encoded;

  _Hello._(this.version, this.mode, this.epk, this.nonce, this.idPub, this.deviceId, this.label, this.encoded);

  factory _Hello.build({
    required int mode,
    required Uint8List epk,
    required Uint8List nonce,
    required Uint8List idPub,
    required String deviceId,
    required String label,
  }) {
    final encoded = _Writer()
        .u8(lanProtocolVersion)
        .u8(mode)
        .raw(epk)
        .raw(nonce)
        .raw(idPub)
        .text(deviceId)
        .text(label)
        .done();
    return _Hello._(lanProtocolVersion, mode, epk, nonce, idPub, deviceId, label, encoded);
  }

  factory _Hello.parse(Uint8List bytes) {
    final r = _Reader(bytes);
    final version = r.u8();
    if (version != lanProtocolVersion) throw const LanProtocolException(LanFailure.unsupportedVersion);
    final mode = r.u8();
    if (mode != LanMode.session.wire && mode != LanMode.pairing.wire) {
      throw const LanProtocolException(LanFailure.malformed);
    }
    final epk = Uint8List.fromList(r.raw(lanKeyLength));
    final nonce = Uint8List.fromList(r.raw(lanKeyLength));
    final idPub = Uint8List.fromList(r.raw(lanKeyLength));
    final deviceId = r.text();
    final label = sanitizeLanLabel(r.text());
    r.expectEnd();
    if (deviceId.isEmpty) throw const LanProtocolException(LanFailure.malformed);
    return _Hello._(version, mode, epk, nonce, idPub, deviceId, label, Uint8List.fromList(bytes));
  }

  LanPeerInfo get peer => LanPeerInfo(publicKey: idPub, deviceId: deviceId, label: label);
}

/// Canal cifrado y autenticado. Un contador por sentido; cualquier fallo de
/// autenticación deja el canal inservible.
class LanSecureChannel {
  final Uint8List _sendKey;
  final Uint8List _recvKey;
  int _sendCounter = 0;
  int _recvCounter = 0;
  bool _dead = false;

  LanSecureChannel({required Uint8List sendKey, required Uint8List recvKey})
      : _sendKey = sendKey,
        _recvKey = recvKey;

  int get framesSent => _sendCounter;
  int get framesReceived => _recvCounter;

  Uint8List _aad(int length) => (ByteData(4)..setUint32(0, length, Endian.big)).buffer.asUint8List();

  Future<Uint8List> seal(int type, [Uint8List? payload]) async {
    if (_dead) throw const LanProtocolException(LanFailure.closed);
    final data = payload ?? Uint8List(0);
    if (data.length > lanChunkBytes) throw const LanProtocolException(LanFailure.frameTooLarge);
    final plain = Uint8List(1 + data.length)
      ..[0] = type
      ..setRange(1, 1 + data.length, data);
    final out = await aeadSeal(
      key: _sendKey,
      counter: _sendCounter,
      plaintext: plain,
      aad: _aad(plain.length + lanTagLength),
    );
    _sendCounter++;
    return out;
  }

  Future<({int type, Uint8List payload})> open(Uint8List sealed) async {
    if (_dead) throw const LanProtocolException(LanFailure.closed);
    if (sealed.length > lanMaxFrameBytes) throw const LanProtocolException(LanFailure.frameTooLarge);
    final Uint8List plain;
    try {
      plain = await aeadOpen(key: _recvKey, counter: _recvCounter, sealed: sealed, aad: _aad(sealed.length));
    } on SecretBoxAuthenticationError {
      _dead = true;
      throw const LanProtocolException(LanFailure.decrypt);
    } on FormatException {
      _dead = true;
      throw const LanProtocolException(LanFailure.decrypt);
    }
    _recvCounter++;
    if (plain.isEmpty) {
      _dead = true;
      throw const LanProtocolException(LanFailure.malformed);
    }
    return (type: plain[0], payload: Uint8List.sublistView(plain, 1));
  }
}

Uint8List _utf(String s) => Uint8List.fromList(utf8.encode(s));

Future<Uint8List> _transcript(Uint8List mI, Uint8List mR) async {
  final b = BytesBuilder(copy: false)
    ..add(_utf('heardy-lan/1'))
    ..add([(mI.length >> 8) & 0xFF, mI.length & 0xFF])
    ..add(mI)
    ..add([(mR.length >> 8) & 0xFF, mR.length & 0xFF])
    ..add(mR);
  return sha256Of(b.toBytes());
}

Future<Uint8List> _commitment(Uint8List mI) => sha256Of([..._utf('heardy-lan/1 commit'), ...mI]);

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Una sola clase para los dos roles; el orden de llamadas lo impone el
/// estado y un paso fuera de orden lanza [LanFailure.unexpectedFrame].
class LanHandshake {
  final bool isInitiator;
  final LanMode mode;
  final LanSigningKey identity;
  final String deviceId;
  final String label;
  final LanTrustCheck isTrusted;
  final RandomBytes random;
  final String? expectedPeerDeviceId;
  final bool pairingAvailable;

  LanEphemeralKey? _eph;
  Uint8List? _nonce;
  _Hello? _mine;
  _Hello? _theirs;
  Uint8List? _commit;
  Uint8List? _th;
  LanSecureChannel? _channel;
  var _step = 0;

  LanHandshake.initiator({
    required this.mode,
    required this.identity,
    required this.deviceId,
    required this.label,
    required this.isTrusted,
    required this.random,
    this.expectedPeerDeviceId,
  })  : isInitiator = true,
        pairingAvailable = false;

  /// [pairingAvailable]: el que escucha tiene abierta la ventana de emparejado.
  LanHandshake.responder({
    required this.identity,
    required this.deviceId,
    required this.label,
    required this.isTrusted,
    required this.random,
    required this.pairingAvailable,
  })  : isInitiator = false,
        mode = LanMode.session,
        expectedPeerDeviceId = null;

  LanPeerInfo? get peer => _theirs?.peer;
  LanSecureChannel get channel => _channel ?? (throw const LanProtocolException(LanFailure.unexpectedFrame));

  /// Modo efectivo (el responder lo conoce al recibir M3).
  LanMode get effectiveMode => isInitiator ? mode : (_theirs?.mode == 1 ? LanMode.pairing : LanMode.session);

  String get sas => _sas ?? (throw const LanProtocolException(LanFailure.unexpectedFrame));
  String? _sas;

  void _need(int step) {
    if (_step != step) throw const LanProtocolException(LanFailure.unexpectedFrame);
  }

  Future<_Hello> _makeHello(LanMode helloMode) async {
    _eph = await LanEphemeralKey.fromSeed(random(lanKeyLength));
    _nonce = random(lanKeyLength);
    return _Hello.build(
      mode: helloMode.wire,
      epk: _eph!.publicKey,
      nonce: _nonce!,
      idPub: identity.publicKey,
      deviceId: deviceId,
      label: label,
    );
  }

  Future<void> _derive() async {
    final mI = isInitiator ? _mine! : _theirs!;
    final mR = isInitiator ? _theirs! : _mine!;
    _th = await _transcript(mI.encoded, mR.encoded);
    final dh = await _eph!.agree(_theirs!.epk);
    final i2r = await hkdfExpand(secret: dh, salt: _th!, info: _utf('heardy-lan/1 i2r'));
    final r2i = await hkdfExpand(secret: dh, salt: _th!, info: _utf('heardy-lan/1 r2i'));
    _channel = isInitiator
        ? LanSecureChannel(sendKey: i2r, recvKey: r2i)
        : LanSecureChannel(sendKey: r2i, recvKey: i2r);
    _sas = sasFromTranscript(await sha256Of([..._utf('heardy-lan/1 sas'), ..._th!]));
  }

  // Iniciador ---------------------------------------------------------------

  Future<Uint8List> start() async {
    _need(0);
    _mine = await _makeHello(mode);
    _commit = await _commitment(_mine!.encoded);
    _step = 1;
    return Uint8List.fromList([_tM1, ..._commit!]);
  }

  /// Procesa M2 y devuelve M3, o lanza si el que responde no sirve.
  Future<Uint8List> onM2(Uint8List m2) async {
    _need(1);
    if (m2.isEmpty || m2[0] != _tM2) throw const LanProtocolException(LanFailure.unexpectedFrame);
    final theirs = _Hello.parse(Uint8List.sublistView(m2, 1));
    if (mode == LanMode.pairing && theirs.mode != LanMode.pairing.wire) {
      throw const LanProtocolException(LanFailure.notPairing);
    }
    if (mode == LanMode.session) {
      if (!isTrusted(theirs.idPub, theirs.deviceId)) throw const LanProtocolException(LanFailure.untrusted);
      if (expectedPeerDeviceId != null && theirs.deviceId != expectedPeerDeviceId) {
        throw const LanProtocolException(LanFailure.wrongPeer);
      }
    }
    _theirs = theirs;
    await _derive();
    _step = 2;
    return Uint8List.fromList([_tM3, ..._mine!.encoded]);
  }

  Future<Uint8List> authFrame() async {
    _need(isInitiator ? 2 : 3);
    final sig = await identity.sign([..._utf('heardy-lan/1 auth ${isInitiator ? 'I' : 'R'}'), ..._th!]);
    _step = isInitiator ? 3 : 4;
    return _channel!.seal(lanFrameAuth, sig);
  }

  /// Verifica la firma del otro. Iniciador: tras M4 enviado; responder: antes de
  /// enviar M5.
  Future<void> onAuth(Uint8List sealed) async {
    _need(isInitiator ? 3 : 2);
    final frame = await _channel!.open(sealed);
    if (frame.type != lanFrameAuth) throw const LanProtocolException(LanFailure.unexpectedFrame);
    final peerRole = isInitiator ? 'R' : 'I';
    final ok = await verifySignature(
      _theirs!.idPub,
      [..._utf('heardy-lan/1 auth $peerRole'), ..._th!],
      Uint8List.fromList(frame.payload),
    );
    if (!ok) throw const LanProtocolException(LanFailure.badSignature);
    _step = isInitiator ? 4 : 3;
  }

  // Responder ---------------------------------------------------------------

  Future<Uint8List> onM1(Uint8List m1) async {
    _need(0);
    if (m1.length != 1 + 32 || m1[0] != _tM1) throw const LanProtocolException(LanFailure.malformed);
    _commit = Uint8List.fromList(m1.sublist(1));
    _mine = await _makeHello(pairingAvailable ? LanMode.pairing : LanMode.session);
    _step = 1;
    return Uint8List.fromList([_tM2, ..._mine!.encoded]);
  }

  Future<void> onM3(Uint8List m3) async {
    _need(1);
    if (m3.isEmpty || m3[0] != _tM3) throw const LanProtocolException(LanFailure.unexpectedFrame);
    final theirs = _Hello.parse(Uint8List.sublistView(m3, 1));
    if (!_bytesEqual(await _commitment(theirs.encoded), _commit!)) {
      throw const LanProtocolException(LanFailure.commitmentMismatch);
    }
    if (theirs.mode == LanMode.pairing.wire) {
      if (!pairingAvailable) throw const LanProtocolException(LanFailure.notPairing);
    } else if (!isTrusted(theirs.idPub, theirs.deviceId)) {
      throw const LanProtocolException(LanFailure.untrusted);
    }
    _theirs = theirs;
    await _derive();
    _step = 2;
  }
}

// Mensajes de datos ------------------------------------------------------------

Future<void> sendFrame(LanFrameIo io, LanSecureChannel channel, int type, [Uint8List? payload]) async =>
    io.write(await channel.seal(type, payload));

Future<({int type, Uint8List payload})> receiveFrame(
  LanFrameIo io,
  LanSecureChannel channel, {
  required Duration timeout,
}) async {
  final sealed = await io.read(timeout: timeout, maxBytes: lanMaxFrameBytes);
  return channel.open(sealed);
}

/// Un mensaje = varias tramas DATA y una END con la longitud total.
Future<void> sendMessage(LanFrameIo io, LanSecureChannel channel, Uint8List bytes) async {
  if (bytes.length > lanMaxPayloadBytes) throw const LanProtocolException(LanFailure.payloadTooLarge);
  for (var offset = 0; offset < bytes.length; offset += lanChunkBytes) {
    final end = offset + lanChunkBytes < bytes.length ? offset + lanChunkBytes : bytes.length;
    await sendFrame(io, channel, lanFrameData, Uint8List.sublistView(bytes, offset, end));
  }
  final total = ByteData(4)..setUint32(0, bytes.length, Endian.big);
  await sendFrame(io, channel, lanFrameEnd, total.buffer.asUint8List());
}

Future<Uint8List> receiveMessage(
  LanFrameIo io,
  LanSecureChannel channel, {
  required Duration timeout,
  int maxBytes = lanMaxPayloadBytes,
}) async {
  final out = BytesBuilder(copy: false);
  while (true) {
    final frame = await receiveFrame(io, channel, timeout: timeout);
    switch (frame.type) {
      case lanFrameData:
        if (out.length + frame.payload.length > maxBytes) {
          throw const LanProtocolException(LanFailure.payloadTooLarge);
        }
        out.add(frame.payload);
      case lanFrameEnd:
        if (frame.payload.length != 4 ||
            ByteData.sublistView(frame.payload).getUint32(0, Endian.big) != out.length) {
          throw const LanProtocolException(LanFailure.malformed);
        }
        return out.toBytes();
      case lanFrameAbort:
        throw const LanProtocolException(LanFailure.peerAborted);
      default:
        throw const LanProtocolException(LanFailure.unexpectedFrame);
    }
  }
}

// Límite de emparejado ----------------------------------------------------------

/// Ventana de emparejado de un solo uso con límite de fallos y enfriamiento.
class LanPairingGate {
  final DateTime Function() _clock;
  final Duration window;
  final int maxFailures;
  final Duration cooldown;

  DateTime? _openUntil;
  DateTime? _coolUntil;
  int _failures = 0;
  bool _attemptActive = false;

  LanPairingGate({
    DateTime Function()? clock,
    this.window = const Duration(seconds: 120),
    this.maxFailures = 5,
    this.cooldown = const Duration(minutes: 5),
  }) : _clock = clock ?? DateTime.now;

  bool get coolingDown {
    final until = _coolUntil;
    if (until == null) return false;
    if (_clock().isBefore(until)) return true;
    _coolUntil = null;
    _failures = 0;
    return false;
  }

  bool get isOpen {
    final until = _openUntil;
    if (until == null || coolingDown) return false;
    if (!_clock().isBefore(until)) {
      _openUntil = null;
      return false;
    }
    return true;
  }

  DateTime? get openUntil => isOpen ? _openUntil : null;

  /// `false` si está en enfriamiento.
  bool open() {
    if (coolingDown) return false;
    _openUntil = _clock().add(window);
    return true;
  }

  void close() {
    _openUntil = null;
  }

  /// Un solo intento de emparejado a la vez.
  bool tryBeginAttempt() {
    if (!isOpen || _attemptActive) return false;
    _attemptActive = true;
    return true;
  }

  bool get attemptActive => _attemptActive;

  void endAttempt() => _attemptActive = false;

  void registerFailure() {
    _failures++;
    if (_failures >= maxFailures) {
      _coolUntil = _clock().add(cooldown);
      _openUntil = null;
    }
  }

  /// Un emparejado exitoso cierra la ventana (un solo uso).
  void registerSuccess() {
    _failures = 0;
    _openUntil = null;
  }
}
