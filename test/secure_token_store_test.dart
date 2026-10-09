// Protección del token de sesión de escritorio: migración desde el valor en
// claro, respaldo cuando el cifrado no está disponible y ida y vuelta real
// con DPAPI en Windows.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:heardy/providers/auth_provider.dart';
import 'package:heardy/services/firebase_rest_auth.dart';
import 'package:heardy/services/secure_token_store.dart';

const _plainTokenKey = 'heardy_desktop_auth_refresh_token';
const _plainEmailKey = 'heardy_desktop_auth_email';
const _secureKey = 'heardy_desktop_auth_secure';

class _FakeSecureTokenStore implements SecureTokenStore {
  _FakeSecureTokenStore({this.failProtect = false, this.failUnprotect = false});

  final bool failProtect;
  final bool failUnprotect;

  @override
  String protect(String plain) {
    if (failProtect) throw StateError('sin cifrado');
    return base64Encode(utf8.encode('fake:$plain'));
  }

  @override
  String unprotect(String protectedValue) {
    if (failUnprotect) throw StateError('sin cifrado');
    final text = utf8.decode(base64Decode(protectedValue));
    if (!text.startsWith('fake:')) throw const FormatException('formato');
    return text.substring(5);
  }
}

class _FakeRestAuthClient implements FirebaseRestAuthClient {
  @override
  String get apiKey => 'fake-key';

  @override
  Future<FirebaseRestSession> signIn(String email, String password) async => FirebaseRestSession(
        idToken: 'id-token-1',
        refreshToken: 'refresh-token-1',
        localId: 'uid-1',
        email: email,
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
      );

  @override
  Future<FirebaseRestSession> signUp(String email, String password) => throw UnimplementedError();

  @override
  Future<FirebaseRestSession> refresh(String refreshToken) async => FirebaseRestSession(
        idToken: 'id-token-2',
        refreshToken: refreshToken,
        localId: 'uid-1',
        email: '',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
      );

  @override
  Future<void> sendPasswordReset(String email) async {}

  @override
  Future<void> sendEmailVerification(String idToken) async {}

  @override
  Future<bool> isEmailVerified(String idToken) async => true;
}

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 80));

void main() {
  group('sesión de escritorio protegida', () {
    test('un token en claro se migra al almacén y la sesión sigue iniciada', () async {
      SharedPreferences.setMockInitialValues({
        _plainTokenKey: 'saved-refresh-token',
        _plainEmailKey: 'saved@example.com',
      });
      final provider = HeardyAuthProvider.rest(client: _FakeRestAuthClient(), tokenStore: _FakeSecureTokenStore());
      await _settle();

      expect(provider.isSignedIn, isTrue);
      expect(provider.email, 'saved@example.com');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(_plainTokenKey), isNull);
      expect(prefs.getString(_plainEmailKey), isNull);
      final blob = prefs.getString(_secureKey)!;
      expect(blob.contains('saved-refresh-token'), isFalse);
      expect(utf8.decode(base64Decode(blob)), contains('saved-refresh-token'));
    });

    test('la sesión ya protegida se restaura sin dejar nada en claro', () async {
      final store = _FakeSecureTokenStore();
      SharedPreferences.setMockInitialValues({
        _secureKey: store.protect(jsonEncode({'refreshToken': 'saved-refresh-token', 'email': 'saved@example.com'})),
      });
      final provider = HeardyAuthProvider.rest(client: _FakeRestAuthClient(), tokenStore: store);
      await _settle();

      expect(provider.isSignedIn, isTrue);
      expect(provider.email, 'saved@example.com');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(_plainTokenKey), isNull);
    });

    test('un inicio de sesión nuevo se guarda cifrado', () async {
      SharedPreferences.setMockInitialValues({});
      final provider = HeardyAuthProvider.rest(client: _FakeRestAuthClient(), tokenStore: _FakeSecureTokenStore());
      await _settle();

      await provider.signIn('user@example.com', 'secret');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(_plainTokenKey), isNull);
      expect(prefs.getString(_secureKey), isNotNull);
    });

    test('si el cifrado falla se conserva el token en claro y no se cierra la sesión', () async {
      SharedPreferences.setMockInitialValues({
        _plainTokenKey: 'saved-refresh-token',
        _plainEmailKey: 'saved@example.com',
      });
      final provider = HeardyAuthProvider.rest(
        client: _FakeRestAuthClient(),
        tokenStore: _FakeSecureTokenStore(failProtect: true),
      );
      await _settle();

      expect(provider.isSignedIn, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(_plainTokenKey), 'saved-refresh-token');
      expect(prefs.getString(_secureKey), isNull);
    });

    test('si no se puede descifrar, cae al token en claro si existe', () async {
      SharedPreferences.setMockInitialValues({
        _secureKey: 'bm8tdmFsaWRv',
        _plainTokenKey: 'saved-refresh-token',
      });
      final provider = HeardyAuthProvider.rest(
        client: _FakeRestAuthClient(),
        tokenStore: _FakeSecureTokenStore(failUnprotect: true),
      );
      await _settle();

      expect(provider.isSignedIn, isTrue);
    });

    test('cerrar sesión borra también el valor cifrado', () async {
      SharedPreferences.setMockInitialValues({});
      final provider = HeardyAuthProvider.rest(client: _FakeRestAuthClient(), tokenStore: _FakeSecureTokenStore());
      await _settle();
      await provider.signIn('user@example.com', 'secret');

      await provider.signOut();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(_secureKey), isNull);
      expect(prefs.getString(_plainTokenKey), isNull);
    });
  });

  group('DPAPI de Windows', () {
    test('ida y vuelta sin dejar el texto en claro', () {
      const store = WindowsDpapiTokenStore();
      const secret = 'refresh-token-ñ-123';
      final blob = store.protect(secret);

      expect(utf8.decode(base64Decode(blob), allowMalformed: true).contains(secret), isFalse);
      expect(store.unprotect(blob), secret);
    }, skip: Platform.isWindows ? false : 'solo Windows');

    test('un valor corrupto lanza en vez de devolver basura', () {
      const store = WindowsDpapiTokenStore();
      expect(() => store.unprotect(base64Encode([1, 2, 3, 4])), throwsA(anything));
    }, skip: Platform.isWindows ? false : 'solo Windows');
  });
}
