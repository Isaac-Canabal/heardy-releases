// Cubre FirebaseRestAuthClient contra un http.Client falso — nunca toca la
// red real. La forma de las respuestas está tomada de la documentación de
// Identity Toolkit v1 (signUp/signInWithPassword/lookup en camelCase,
// securetoken:token en snake_case — son endpoints distintos de Google, no
// una inconsistencia de este cliente).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:heardy/services/firebase_rest_auth.dart';

class _FakeClient extends http.BaseClient {
  _FakeClient(this.handler);
  final http.Response Function(http.Request request) handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await request.finalize().bytesToString();
    final response = handler(
      http.Request(request.method, request.url)..body = body,
    );
    return http.StreamedResponse(
      Stream.value(utf8.encode(response.body)),
      response.statusCode,
    );
  }
}

FirebaseRestAuthClient _clientWith(
  http.Response Function(http.Request request) handler,
) {
  return FirebaseRestAuthClient(
    apiKey: 'fake-key',
    clientFactory: () => _FakeClient(handler),
  );
}

void main() {
  group('FirebaseRestAuthClient', () {
    test('signIn exitoso arma la sesión desde la respuesta camelCase', () async {
      final client = _clientWith((request) {
        expect(request.url.path, contains('accounts:signInWithPassword'));
        final payload = jsonDecode(request.body) as Map<String, dynamic>;
        expect(payload['email'], 'user@example.com');
        return http.Response(
          jsonEncode({
            'idToken': 'id-token-1',
            'refreshToken': 'refresh-token-1',
            'localId': 'uid-1',
            'email': 'user@example.com',
            'expiresIn': '3600',
          }),
          200,
        );
      });

      final session = await client.signIn('user@example.com', 'secret');

      expect(session.idToken, 'id-token-1');
      expect(session.refreshToken, 'refresh-token-1');
      expect(session.localId, 'uid-1');
      expect(session.email, 'user@example.com');
      expect(
        session.expiresAt.difference(DateTime.now()).inMinutes,
        greaterThan(55),
      );
    });

    test('un error de la API lanza FirebaseRestAuthException con el código de Google', () async {
      final client = _clientWith((request) {
        return http.Response(
          jsonEncode({
            'error': {
              'code': 400,
              'message': 'EMAIL_EXISTS',
              'errors': [
                {'message': 'EMAIL_EXISTS'},
              ],
            },
          }),
          400,
        );
      });

      expect(
        () => client.signUp('user@example.com', 'secret'),
        throwsA(
          isA<FirebaseRestAuthException>().having(
            (e) => e.code,
            'code',
            'EMAIL_EXISTS',
          ),
        ),
      );
    });

    test('refresh parsea la respuesta snake_case de securetoken, no camelCase', () async {
      final client = _clientWith((request) {
        expect(request.url.host, 'securetoken.googleapis.com');
        return http.Response(
          jsonEncode({
            'access_token': 'ignored',
            'expires_in': '3600',
            'token_type': 'Bearer',
            'refresh_token': 'refresh-token-2',
            'id_token': 'id-token-2',
            'user_id': 'uid-1',
            'project_id': '462683095100',
          }),
          200,
        );
      });

      final session = await client.refresh('refresh-token-1');

      expect(session.idToken, 'id-token-2');
      expect(session.refreshToken, 'refresh-token-2');
      expect(session.localId, 'uid-1');
    });

    test('isEmailVerified lee el primer usuario de accounts:lookup', () async {
      final verifiedClient = _clientWith((request) {
        expect(request.url.path, contains('accounts:lookup'));
        return http.Response(
          jsonEncode({
            'users': [
              {'localId': 'uid-1', 'emailVerified': true},
            ],
          }),
          200,
        );
      });
      expect(await verifiedClient.isEmailVerified('id-token-1'), isTrue);

      final unverifiedClient = _clientWith((request) {
        return http.Response(
          jsonEncode({
            'users': [
              {'localId': 'uid-1', 'emailVerified': false},
            ],
          }),
          200,
        );
      });
      expect(await unverifiedClient.isEmailVerified('id-token-1'), isFalse);
    });
  });
}
