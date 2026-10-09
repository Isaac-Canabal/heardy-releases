import 'dart:convert';

import 'package:http/http.dart' as http;

/// La clave de API "Web" de Firebase para `heardy-001`, registrada para el
/// cliente de escritorio (W5 del plan de escritorio). **No es un secreto**:
/// Google documenta esta clave como segura de publicar — sólo identifica el
/// proyecto, no autoriza nada por sí sola. La protección real es la
/// restricción de la clave en Google Cloud Console (mismo criterio que la
/// clave de `android/app/google-services.json`, ver las notas de trabajo
/// locales). Nunca poner acá la clave del servidor de descargas ni ningún
/// secreto real de servidor.
const String firebaseWebApiKey = 'AIzaSyC5Ctzpp8eMdyp6vDPoM4FXzIofTtk9g7I';

/// Error de la API REST de Identity Toolkit, con el código corto que Firebase
/// devuelve (`EMAIL_EXISTS`, `INVALID_LOGIN_CREDENTIALS`, `WEAK_PASSWORD`...)
/// — el mismo vocabulario de errores que el SDK móvil traduce a
/// `FirebaseAuthException.code`, así que las pantallas existentes que ya
/// saben mapear códigos a mensajes no necesitan lógica nueva por plataforma.
class FirebaseRestAuthException implements Exception {
  final String code;
  const FirebaseRestAuthException(this.code);

  @override
  String toString() => code;
}

class FirebaseRestSession {
  final String idToken;
  final String refreshToken;
  final String localId;
  final String email;
  final DateTime expiresAt;

  const FirebaseRestSession({
    required this.idToken,
    required this.refreshToken,
    required this.localId,
    required this.email,
    required this.expiresAt,
  });
}

/// Cliente HTTP puro para Firebase Auth vía su API REST — la vía que
/// `firebase_auth` (el SDK) no puede tomar en escritorio: Google no lo
/// considera apto para producción en Windows (Hallazgo 3 del plan de
/// escritorio). El servidor no necesita ningún cambio: el token que emite
/// esta API es idéntico al del SDK y `firebase_auth.py` ya lo verifica por
/// firma.
class FirebaseRestAuthClient {
  static const _identityBase = 'https://identitytoolkit.googleapis.com/v1';
  static const _secureTokenBase = 'https://securetoken.googleapis.com/v1';

  final String apiKey;
  final http.Client Function() _clientFactory;

  FirebaseRestAuthClient({
    this.apiKey = firebaseWebApiKey,
    http.Client Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? (() => http.Client());

  Future<FirebaseRestSession> signUp(String email, String password) =>
      _sessionCall('accounts:signUp', {
        'email': email,
        'password': password,
        'returnSecureToken': true,
      });

  Future<FirebaseRestSession> signIn(String email, String password) =>
      _sessionCall('accounts:signInWithPassword', {
        'email': email,
        'password': password,
        'returnSecureToken': true,
      });

  /// Intercambia un refresh token por un id token nuevo. **Forma de
  /// respuesta distinta a las demás** (snake_case, endpoint separado) — así
  /// es como Google define este endpoint, no una inconsistencia de acá.
  Future<FirebaseRestSession> refresh(String refreshToken) async {
    final client = _clientFactory();
    try {
      final response = await client
          .post(
            Uri.parse('$_secureTokenBase/token?key=$apiKey'),
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
            body: {'grant_type': 'refresh_token', 'refresh_token': refreshToken},
          )
          .timeout(const Duration(seconds: 20));
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode != 200) {
        throw FirebaseRestAuthException(_errorCode(body));
      }
      return FirebaseRestSession(
        idToken: body['id_token'] as String,
        refreshToken: body['refresh_token'] as String,
        localId: body['user_id'] as String,
        // El endpoint de refresh no devuelve el email — se conserva el que
        // ya se tenía guardado, se pasa por fuera de este cliente.
        email: '',
        expiresAt: DateTime.now().add(
          Duration(seconds: int.parse(body['expires_in'] as String)),
        ),
      );
    } finally {
      client.close();
    }
  }

  Future<void> sendPasswordReset(String email) => _voidCall('accounts:sendOobCode', {
        'requestType': 'PASSWORD_RESET',
        'email': email,
      });

  Future<void> sendEmailVerification(String idToken) => _voidCall('accounts:sendOobCode', {
        'requestType': 'VERIFY_EMAIL',
        'idToken': idToken,
      });

  /// `true` si la cuenta identificada por [idToken] ya tiene el correo
  /// verificado — el equivalente REST de `User.reload()` + `emailVerified`.
  Future<bool> isEmailVerified(String idToken) async {
    final body = await _call('accounts:lookup', {'idToken': idToken});
    final users = body['users'] as List<dynamic>?;
    if (users == null || users.isEmpty) return false;
    return (users.first as Map<String, dynamic>)['emailVerified'] as bool? ?? false;
  }

  Future<FirebaseRestSession> _sessionCall(
    String endpoint,
    Map<String, dynamic> payload,
  ) async {
    final body = await _call(endpoint, payload);
    return FirebaseRestSession(
      idToken: body['idToken'] as String,
      refreshToken: body['refreshToken'] as String,
      localId: body['localId'] as String,
      email: body['email'] as String,
      expiresAt: DateTime.now().add(
        Duration(seconds: int.parse(body['expiresIn'] as String)),
      ),
    );
  }

  Future<void> _voidCall(String endpoint, Map<String, dynamic> payload) async {
    await _call(endpoint, payload);
  }

  Future<Map<String, dynamic>> _call(
    String endpoint,
    Map<String, dynamic> payload,
  ) async {
    final client = _clientFactory();
    try {
      final response = await client
          .post(
            Uri.parse('$_identityBase/$endpoint?key=$apiKey'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 20));
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode != 200) {
        throw FirebaseRestAuthException(_errorCode(body));
      }
      return body;
    } finally {
      client.close();
    }
  }

  /// El primer código de la lista de `error.errors[].message`, o el mensaje
  /// general si esa lista no viene — igual de tolerante que el resto del
  /// código con respuestas de red que no vienen exactamente como se espera.
  String _errorCode(Map<String, dynamic> body) {
    final error = body['error'] as Map<String, dynamic>?;
    if (error == null) return 'UNKNOWN_ERROR';
    final errors = error['errors'] as List<dynamic>?;
    if (errors != null && errors.isNotEmpty) {
      final message = (errors.first as Map<String, dynamic>)['message'] as String?;
      if (message != null) return message;
    }
    return (error['message'] as String?) ?? 'UNKNOWN_ERROR';
  }
}
