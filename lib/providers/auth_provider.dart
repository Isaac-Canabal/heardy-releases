import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/firebase_rest_auth.dart';
import '../services/secure_token_store.dart';
import 'package:heardy/services/app_log.dart';

/// Identidad de cuenta para el servidor de descargas oficial (Fase 2 del
/// plan de seguridad, ver CLAUDE.md "Próxima sesión — retomar aquí"):
/// reemplaza la clave de API única compilada en el binario (A1, hallazgo
/// cerrado por esto) por una cuenta real por persona vía Firebase Auth.
///
/// Deliberadamente no toca nada del resto de la app: la biblioteca local, la
/// reproducción, la bandeja y la búsqueda local funcionan sin sesión — sólo
/// [ImportScreen]/[SearchScreen] (las dos pantallas que hablan con el
/// servidor) leen [isReady] antes de dejar descargar algo.
class HeardyAuthProvider with ChangeNotifier {
  final FirebaseAuth? _auth;
  final FirebaseRestAuthClient? _rest;
  StreamSubscription<User?>? _sub;

  /// Sólo para [HeardyAuthProvider.fake] — nunca puesto por el constructor normal.
  final bool _fakeReady;
  final String? _fakeEmail;

  // Estado de sesión sólo para [HeardyAuthProvider.rest] — el SDK móvil
  // gestiona todo esto por su cuenta, pero hablando HTTP puro hay que
  // llevarlo a mano.
  String? _restIdToken;
  String? _restRefreshToken;
  DateTime? _restExpiresAt;
  String? _restEmail;
  bool _restEmailVerified = false;

  static const _restRefreshTokenKey = 'heardy_desktop_auth_refresh_token';
  static const _restEmailKey = 'heardy_desktop_auth_email';
  static const _restSecureKey = 'heardy_desktop_auth_secure';

  final SecureTokenStore? _tokenStore;

  HeardyAuthProvider({FirebaseAuth? auth})
      : _auth = auth ?? FirebaseAuth.instance,
        _rest = null,
        _fakeReady = false,
        _fakeEmail = null,
        _tokenStore = null {
    _sub = _auth!.userChanges().listen((_) => notifyListeners());
  }

  /// Doble de prueba que nunca toca `FirebaseAuth.instance` — un widget test
  /// no tiene `Firebase.initializeApp()` corrido, así que el constructor
  /// normal explotaría antes de llegar a `pumpWidget`. `ImportScreen`/
  /// `SearchScreen` sólo leen [isReady]/[email] de este provider, así que eso
  /// es lo único que hace falta simular; el resto de los métodos no se
  /// invocan en esos flujos y lanzan [UnimplementedError] si algo los llama
  /// por error.
  HeardyAuthProvider.fake({bool isReady = true, String? email})
      : _auth = null,
        _rest = null,
        _fakeReady = isReady,
        _fakeEmail = email,
        _tokenStore = null;

  /// Escritorio (W5 del plan de escritorio): Firebase Auth no es apto para
  /// producción en Windows (Hallazgo 3 — Google lo dice en su propia
  /// documentación), así que en vez del SDK se habla con la API REST de
  /// Identity Toolkit por HTTP. La sesión (el refresh token) se persiste a
  /// mano en `SharedPreferences` porque, a diferencia del SDK móvil, nada
  /// más lo hace por acá.
  HeardyAuthProvider.rest({FirebaseRestAuthClient? client, SecureTokenStore? tokenStore})
      : _auth = null,
        _rest = client ?? FirebaseRestAuthClient(),
        _fakeReady = false,
        _fakeEmail = null,
        _tokenStore = tokenStore ?? defaultSecureTokenStore() {
    _restoreRestSession();
  }

  bool get _isFake => _auth == null && _rest == null;

  User? get user => _auth?.currentUser;
  bool get isSignedIn =>
      _isFake ? _fakeReady : (_rest != null ? _restRefreshToken != null : user != null);

  /// Sin correo verificado, la app trata la cuenta como si no existiera de
  /// cara al servidor (D-1 del plan: la verificación por correo es el único
  /// control de alta que hace exigible la cuota de la Fase 3 — sin él,
  /// registrarse es gratis e infinito).
  bool get isEmailVerified =>
      _isFake ? _fakeReady : (_rest != null ? _restEmailVerified : (user?.emailVerified ?? false));
  bool get isReady => _isFake ? _fakeReady : (isSignedIn && isEmailVerified);
  String? get email => _isFake ? _fakeEmail : (_rest != null ? _restEmail : user?.email);

  /// Token de ID para `Authorization: Bearer <token>`. El SDK lo cachea y
  /// sólo lo refresca de verdad cuando hace falta (o cuando [forceRefresh]
  /// lo pide) — no hay que guardarlo a mano ni preocuparse por su expiración.
  /// En modo REST se replica lo mismo a mano: refrescar sólo si está por
  /// caducar (o si se pide a la fuerza), nunca en cada llamada.
  Future<String?> idToken({bool forceRefresh = false}) async {
    if (_isFake) return _fakeReady ? 'fake-token' : null;
    if (_rest != null) {
      final refreshToken = _restRefreshToken;
      if (refreshToken == null) return null;
      final expiringSoon = forceRefresh ||
          _restExpiresAt == null ||
          DateTime.now().isAfter(_restExpiresAt!.subtract(const Duration(minutes: 5)));
      if (expiringSoon) {
        try {
          final session = await _rest.refresh(refreshToken);
          _restIdToken = session.idToken;
          _restRefreshToken = session.refreshToken;
          _restExpiresAt = session.expiresAt;
          await _persistRestSession();
        } catch (e) {
          appLog('HeardyAuthProvider: no se pudo refrescar el token: $e');
          return null;
        }
      }
      return _restIdToken;
    }
    final current = user;
    if (current == null) return null;
    return current.getIdToken(forceRefresh);
  }

  Future<void> register(String email, String password) async {
    if (_rest != null) {
      final session = await _rest.signUp(email.trim(), password);
      await _rest.sendEmailVerification(session.idToken);
      await _applyRestSession(session);
      return;
    }
    final credential = await _auth!.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    await credential.user?.sendEmailVerification();
  }

  Future<void> signIn(String email, String password) async {
    if (_rest != null) {
      final session = await _rest.signIn(email.trim(), password);
      await _applyRestSession(session);
      return;
    }
    await _auth!.signInWithEmailAndPassword(email: email.trim(), password: password);
  }

  Future<void> signOut() async {
    if (_rest != null) {
      _restIdToken = null;
      _restRefreshToken = null;
      _restExpiresAt = null;
      _restEmail = null;
      _restEmailVerified = false;
      await _clearRestSession();
      notifyListeners();
      return;
    }
    await _auth!.signOut();
  }

  Future<void> sendPasswordReset(String email) {
    if (_rest != null) return _rest.sendPasswordReset(email.trim());
    return _auth!.sendPasswordResetEmail(email: email.trim());
  }

  Future<void> resendVerificationEmail() async {
    if (_rest != null) {
      final token = _restIdToken;
      if (token != null) await _rest.sendEmailVerification(token);
      return;
    }
    await _auth!.currentUser?.sendEmailVerification();
  }

  /// Vuelve a leer el estado de la cuenta desde Firebase — hace falta tras
  /// verificar el correo en otra pestaña, porque el token en memoria no se
  /// entera solo.
  ///
  /// Y por eso mismo fuerza un token nuevo en cuanto el correo consta como
  /// verificado: `User.reload()` refresca el registro de la cuenta, pero
  /// **no** el token de ID cacheado, que sigue llevando
  /// `email_verified: false` hasta que caduque (una hora). El servidor mira
  /// ese claim del token, no el estado local (ver `verify_id_token` en
  /// `server/app/firebase_auth.py`), así que sin este refresco la app daría
  /// la cuenta por lista ([isReady]) y la primera descarga se comería un 403
  /// — justo en el minuto siguiente a verificar el correo, que es cuando
  /// todo el mundo lo prueba. Misma lógica en modo REST, con
  /// `accounts:lookup` en vez de `User.reload()`.
  Future<void> reload() async {
    if (_rest != null) {
      final token = _restIdToken;
      if (token == null) return;
      try {
        final verified = await _rest.isEmailVerified(token);
        final justVerified = verified && !_restEmailVerified;
        _restEmailVerified = verified;
        if (justVerified) await idToken(forceRefresh: true);
      } catch (e) {
        appLog('HeardyAuthProvider: no se pudo comprobar el correo verificado: $e');
      }
      notifyListeners();
      return;
    }
    await _auth!.currentUser?.reload();
    if (_auth.currentUser?.emailVerified ?? false) {
      await _auth.currentUser?.getIdToken(true);
    }
    notifyListeners();
  }

  Future<void> _applyRestSession(FirebaseRestSession session) async {
    _restIdToken = session.idToken;
    _restRefreshToken = session.refreshToken;
    _restExpiresAt = session.expiresAt;
    _restEmail = session.email;
    await _persistRestSession();
    try {
      _restEmailVerified = await _rest!.isEmailVerified(session.idToken);
    } catch (_) {
      _restEmailVerified = false;
    }
    notifyListeners();
  }

  /// Restaura una sesión guardada al arrancar. Notifica dos veces a
  /// propósito: una apenas se lee el refresh token guardado en
  /// `SharedPreferences` (así `isSignedIn` no depende de que la red
  /// responda), y otra tras comprobar de verdad el token y el correo
  /// verificado.
  Future<void> _restoreRestSession() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = await _readStoredSession(prefs);
    if (stored == null) return;
    _restRefreshToken = stored.refreshToken;
    _restEmail = stored.email;
    notifyListeners();
    await idToken();
    await reload();
  }

  Future<({String refreshToken, String? email})?> _readStoredSession(SharedPreferences prefs) async {
    final store = _tokenStore;
    final secure = prefs.getString(_restSecureKey);
    if (store != null && secure != null) {
      try {
        final decoded = jsonDecode(store.unprotect(secure));
        if (decoded is Map && decoded['refreshToken'] is String) {
          return (refreshToken: decoded['refreshToken'] as String, email: decoded['email'] as String?);
        }
      } catch (e) {
        appLog('HeardyAuthProvider: no se pudo leer la sesión protegida: ${e.runtimeType}');
      }
    }
    final refreshToken = prefs.getString(_restRefreshTokenKey);
    if (refreshToken == null) return null;
    final email = prefs.getString(_restEmailKey);
    if (store != null) {
      await _trySaveProtected(prefs, store, refreshToken, email);
    }
    return (refreshToken: refreshToken, email: email);
  }

  Future<bool> _trySaveProtected(
    SharedPreferences prefs,
    SecureTokenStore store,
    String refreshToken,
    String? email,
  ) async {
    try {
      final blob = store.protect(jsonEncode({'refreshToken': refreshToken, 'email': email}));
      await prefs.setString(_restSecureKey, blob);
      await prefs.remove(_restRefreshTokenKey);
      await prefs.remove(_restEmailKey);
      return true;
    } catch (e) {
      appLog('HeardyAuthProvider: no se pudo proteger la sesión: ${e.runtimeType}');
      return false;
    }
  }

  Future<void> _persistRestSession() async {
    final prefs = await SharedPreferences.getInstance();
    final refreshToken = _restRefreshToken;
    if (refreshToken == null) return;
    final store = _tokenStore;
    if (store != null && await _trySaveProtected(prefs, store, refreshToken, _restEmail)) return;
    await prefs.setString(_restRefreshTokenKey, refreshToken);
    final email = _restEmail;
    if (email != null) await prefs.setString(_restEmailKey, email);
  }

  Future<void> _clearRestSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_restRefreshTokenKey);
    await prefs.remove(_restEmailKey);
    await prefs.remove(_restSecureKey);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
