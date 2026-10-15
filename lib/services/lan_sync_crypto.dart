/// Primitivas de la sincronización por Wi-Fi, todas de `package:cryptography`
/// (Dart puro): X25519, Ed25519, ChaCha20-Poly1305, HKDF-SHA256 y SHA-256.
/// Nada de criptografía propia; este archivo solo fija parámetros y formatos.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

typedef RandomBytes = Uint8List Function(int length);

Uint8List secureRandomBytes(int length) {
  final rng = Random.secure();
  return Uint8List.fromList(List<int>.generate(length, (_) => rng.nextInt(256)));
}

const lanKeyLength = 32;
const lanSignatureLength = 64;
const lanTagLength = 16;
const lanNonceLength = 12;

final _x25519 = X25519();
final _ed25519 = Ed25519();
final _aead = Chacha20.poly1305Aead();
final _sha256 = Sha256();
final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: lanKeyLength);

Future<Uint8List> sha256Of(List<int> data) async => Uint8List.fromList((await _sha256.hash(data)).bytes);

class LanEphemeralKey {
  final SimpleKeyPair keyPair;
  final Uint8List publicKey;
  LanEphemeralKey._(this.keyPair, this.publicKey);

  static Future<LanEphemeralKey> fromSeed(Uint8List seed) async {
    final pair = await _x25519.newKeyPairFromSeed(seed);
    final pub = await pair.extractPublicKey();
    return LanEphemeralKey._(pair, Uint8List.fromList(pub.bytes));
  }

  /// Rechaza puntos de orden bajo (secreto compartido todo ceros).
  Future<Uint8List> agree(Uint8List remotePublicKey) async {
    if (remotePublicKey.length != lanKeyLength) throw const FormatException('clave efímera inválida');
    final secret = await _x25519.sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: SimplePublicKey(remotePublicKey, type: KeyPairType.x25519),
    );
    final bytes = Uint8List.fromList(await secret.extractBytes());
    if (bytes.every((b) => b == 0)) throw const FormatException('secreto compartido degenerado');
    return bytes;
  }
}

class LanSigningKey {
  final SimpleKeyPair keyPair;
  final Uint8List publicKey;
  final Uint8List seed;
  LanSigningKey._(this.keyPair, this.publicKey, this.seed);

  static Future<LanSigningKey> fromSeed(Uint8List seed) async {
    final pair = await _ed25519.newKeyPairFromSeed(seed);
    final pub = await pair.extractPublicKey();
    return LanSigningKey._(pair, Uint8List.fromList(pub.bytes), Uint8List.fromList(seed));
  }

  Future<Uint8List> sign(List<int> message) async =>
      Uint8List.fromList((await _ed25519.sign(message, keyPair: keyPair)).bytes);
}

Future<bool> verifySignature(Uint8List publicKey, List<int> message, Uint8List signature) async {
  if (publicKey.length != lanKeyLength || signature.length != lanSignatureLength) return false;
  try {
    return await _ed25519.verify(
      message,
      signature: Signature(signature, publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519)),
    );
  } catch (_) {
    return false;
  }
}

Future<Uint8List> hkdfExpand({
  required Uint8List secret,
  required Uint8List salt,
  required List<int> info,
}) async {
  final key = await _hkdf.deriveKey(secretKey: SecretKey(secret), nonce: salt, info: info);
  return Uint8List.fromList(await key.extractBytes());
}

/// Nonce de 96 bits = 4 bytes en cero + contador de 64 bits. Cada dirección
/// tiene su propia clave y su propio contador, así que no se repite nunca.
Uint8List lanNonce(int counter) {
  final nonce = Uint8List(lanNonceLength);
  ByteData.sublistView(nonce).setUint64(4, counter, Endian.big);
  return nonce;
}

Future<Uint8List> aeadSeal({
  required Uint8List key,
  required int counter,
  required Uint8List plaintext,
  required List<int> aad,
}) async {
  final box = await _aead.encrypt(plaintext, secretKey: SecretKey(key), nonce: lanNonce(counter), aad: aad);
  return Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
}

/// Lanza [SecretBoxAuthenticationError] si la etiqueta no coincide.
Future<Uint8List> aeadOpen({
  required Uint8List key,
  required int counter,
  required Uint8List sealed,
  required List<int> aad,
}) async {
  if (sealed.length < lanTagLength) throw const FormatException('trama demasiado corta');
  final split = sealed.length - lanTagLength;
  final box = SecretBox(
    sealed.sublist(0, split),
    nonce: lanNonce(counter),
    mac: Mac(sealed.sublist(split)),
  );
  return Uint8List.fromList(await _aead.decrypt(box, secretKey: SecretKey(key), aad: aad));
}

const lanSasDigits = 8;

/// Cadena de autenticación corta: 8 dígitos de 48 bits del hash de la
/// transcripción (el sesgo del módulo es despreciable). Se muestra en los dos
/// dispositivos.
String sasFromTranscript(Uint8List transcriptHash) {
  final d = ByteData.sublistView(transcriptHash);
  final value = (d.getUint16(0, Endian.big) * 0x100000000 + d.getUint32(2, Endian.big)) % 100000000;
  return value.toString().padLeft(lanSasDigits, '0');
}

/// Huella corta de una clave pública de identidad: 8 hex de su SHA-256 en dos
/// grupos, para reconocer un dispositivo aunque otro use su misma etiqueta.
String lanKeyFingerprint(Uint8List publicKey) {
  final hex = crypto.sha256.convert(publicKey).toString().substring(0, 8);
  return '${hex.substring(0, 4)} ${hex.substring(4)}';
}
