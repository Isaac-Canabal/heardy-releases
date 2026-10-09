// Cubre el modo HeardyAuthProvider.rest() (W5 del plan de escritorio) contra
// un FirebaseRestAuthClient falso — nunca toca la red ni SharedPreferences
// real.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:heardy/providers/auth_provider.dart';
import 'package:heardy/services/firebase_rest_auth.dart';

class _FakeRestAuthClient implements FirebaseRestAuthClient {
  int signInCalls = 0;
  int refreshCalls = 0;
  int lookupCalls = 0;
  bool emailVerified = false;

  @override
  String get apiKey => 'fake-key';

  @override
  Future<FirebaseRestSession> signIn(String email, String password) async {
    signInCalls++;
    return FirebaseRestSession(
      idToken: 'id-token-1',
      refreshToken: 'refresh-token-1',
      localId: 'uid-1',
      email: email,
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
    );
  }

  @override
  Future<FirebaseRestSession> signUp(String email, String password) =>
      throw UnimplementedError();

  @override
  Future<FirebaseRestSession> refresh(String refreshToken) async {
    refreshCalls++;
    return FirebaseRestSession(
      idToken: 'id-token-2',
      refreshToken: refreshToken,
      localId: 'uid-1',
      email: '',
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
    );
  }

  @override
  Future<void> sendPasswordReset(String email) async {}

  @override
  Future<void> sendEmailVerification(String idToken) async {}

  @override
  Future<bool> isEmailVerified(String idToken) async {
    lookupCalls++;
    return emailVerified;
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('HeardyAuthProvider.rest', () {
    test('sin sesión guardada, arranca sin sesión', () async {
      final provider = HeardyAuthProvider.rest(client: _FakeRestAuthClient());
      // _restoreRestSession sale de inmediato sin refresh token guardado.
      await Future<void>.delayed(Duration.zero);

      expect(provider.isSignedIn, isFalse);
      expect(provider.isReady, isFalse);
      expect(await provider.idToken(), isNull);
    });

    test('signIn deja la sesión lista si el correo ya está verificado', () async {
      final client = _FakeRestAuthClient()..emailVerified = true;
      final provider = HeardyAuthProvider.rest(client: client);
      await Future<void>.delayed(Duration.zero);

      await provider.signIn('user@example.com', 'secret');

      expect(provider.isSignedIn, isTrue);
      expect(provider.isEmailVerified, isTrue);
      expect(provider.isReady, isTrue);
      expect(provider.email, 'user@example.com');
      expect(client.signInCalls, 1);
    });

    test('signIn con correo sin verificar dice isReady=false, no isSignedIn=false', () async {
      final client = _FakeRestAuthClient()..emailVerified = false;
      final provider = HeardyAuthProvider.rest(client: client);
      await Future<void>.delayed(Duration.zero);

      await provider.signIn('user@example.com', 'secret');

      expect(provider.isSignedIn, isTrue);
      expect(provider.isEmailVerified, isFalse);
      expect(provider.isReady, isFalse);
    });

    test('idToken no refresca si el token todavía no está por caducar', () async {
      final client = _FakeRestAuthClient()..emailVerified = true;
      final provider = HeardyAuthProvider.rest(client: client);
      await Future<void>.delayed(Duration.zero);
      await provider.signIn('user@example.com', 'secret');

      final token = await provider.idToken();

      expect(token, 'id-token-1');
      expect(client.refreshCalls, 0, reason: 'recién firmado, no debería refrescar todavía');
    });

    test('signOut borra la sesión', () async {
      final client = _FakeRestAuthClient()..emailVerified = true;
      final provider = HeardyAuthProvider.rest(client: client);
      await Future<void>.delayed(Duration.zero);
      await provider.signIn('user@example.com', 'secret');

      await provider.signOut();

      expect(provider.isSignedIn, isFalse);
      expect(provider.email, isNull);
      expect(await provider.idToken(), isNull);
    });

    test('una sesión guardada se restaura y refresca el token al arrancar', () async {
      SharedPreferences.setMockInitialValues({
        'heardy_desktop_auth_refresh_token': 'saved-refresh-token',
        'heardy_desktop_auth_email': 'saved@example.com',
      });
      final client = _FakeRestAuthClient()..emailVerified = true;
      final provider = HeardyAuthProvider.rest(client: client);

      // Deja correr toda la cadena async de restauración (leer prefs,
      // refrescar el token, comprobar el correo verificado).
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(provider.isSignedIn, isTrue);

      expect(client.refreshCalls, greaterThanOrEqualTo(1));
      expect(provider.isReady, isTrue);
      expect(provider.email, 'saved@example.com');
    });
  });
}
