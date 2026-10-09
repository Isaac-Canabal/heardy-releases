import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Cifra y descifra un texto con una protección ligada al usuario del sistema.
/// El resultado es base64, apto para guardarlo en `SharedPreferences`.
/// Lanza si la operación no es posible; quien llama decide el respaldo.
abstract class SecureTokenStore {
  String protect(String plain);
  String unprotect(String protectedValue);
}

/// DPAPI de Windows (`CryptProtectData`, ámbito de usuario): sólo la misma
/// cuenta de Windows en esta máquina puede descifrar el resultado.
class WindowsDpapiTokenStore implements SecureTokenStore {
  const WindowsDpapiTokenStore();

  static const _uiForbidden = 0x1;

  @override
  String protect(String plain) {
    final bytes = Uint8List.fromList(utf8.encode(plain));
    return base64Encode(_transform(bytes, protect: true));
  }

  @override
  String unprotect(String protectedValue) {
    final bytes = base64Decode(protectedValue);
    return utf8.decode(_transform(bytes, protect: false));
  }

  Uint8List _transform(Uint8List input, {required bool protect}) {
    if (!Platform.isWindows) throw UnsupportedError('DPAPI solo está disponible en Windows');
    final inBlob = calloc<CRYPT_INTEGER_BLOB>();
    final outBlob = calloc<CRYPT_INTEGER_BLOB>();
    final data = calloc<Uint8>(input.isEmpty ? 1 : input.length);
    try {
      data.asTypedList(input.length).setAll(0, input);
      inBlob.ref
        ..cbData = input.length
        ..pbData = data;
      final ok = protect
          ? CryptProtectData(inBlob, nullptr, nullptr, nullptr, nullptr, _uiForbidden, outBlob)
          : CryptUnprotectData(inBlob, nullptr, nullptr, nullptr, nullptr, _uiForbidden, outBlob);
      if (ok == 0) throw StateError('DPAPI falló');
      try {
        return Uint8List.fromList(outBlob.ref.pbData.asTypedList(outBlob.ref.cbData));
      } finally {
        LocalFree(outBlob.ref.pbData);
      }
    } finally {
      calloc.free(data);
      calloc.free(inBlob);
      calloc.free(outBlob);
    }
  }
}

/// Almacén de Windows en escritorio Windows; `null` en el resto, donde el
/// token sigue como hasta ahora.
SecureTokenStore? defaultSecureTokenStore() => Platform.isWindows ? const WindowsDpapiTokenStore() : null;
