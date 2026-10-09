// Cada respuesta del servidor debe acabar en una frase clara, en el idioma
// elegido, sin texto técnico: ni excepciones, ni JSON, ni "null".
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:heardy/l10n/app_localizations.dart';
import 'package:heardy/l10n/app_localizations_en.dart';
import 'package:heardy/l10n/app_localizations_es.dart';
import 'package:heardy/services/cloud_source.dart';
import 'package:heardy/services/download_source.dart';
import 'package:heardy/services/friendly_error.dart';
import 'package:heardy/services/heardy_cloud_source.dart';
import 'package:heardy/services/ytdlp_server_source.dart';

class _FakeClient extends http.BaseClient {
  _FakeClient(this.handler);
  final http.StreamedResponse Function() handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async => handler();
}

http.StreamedResponse _resp(int status, Object body, {Map<String, String>? headers}) {
  final bytes = utf8.encode(body is String ? body : jsonEncode(body));
  return http.StreamedResponse(
    Stream.value(bytes),
    status,
    contentLength: bytes.length,
    headers: {'content-type': 'application/json', ...?headers},
  );
}

const _forbidden = ['Exception', 'Error:', 'TypeError', '{', '}', 'null', 'Traceback', 'SocketException'];

void _expectClean(String message, {String? reason}) {
  expect(message.trim(), isNotEmpty, reason: reason);
  for (final bad in _forbidden) {
    expect(message.contains(bad), isFalse, reason: '${reason ?? ''} contiene "$bad": $message');
  }
}

Future<DownloadSourceException> _downloadError(int status, Object body, {Map<String, String>? headers}) async {
  final source = YtdlpServerSource(
    baseUrl: () => 'http://servidor:8080',
    authToken: () async => 'token',
    clientFactory: () => _FakeClient(() => _resp(status, body, headers: headers)),
  );
  try {
    await source.resolve('https://youtu.be/abc');
  } on DownloadSourceException catch (e) {
    return e;
  }
  fail('debía lanzar');
}

Future<CloudSourceException> _cloudError(int status, Object body, {Map<String, String>? headers}) async {
  final source = HeardyCloudSource(
    baseUrl: () => 'http://servidor:8080',
    authToken: () async => 'token',
    clientFactory: () => _FakeClient(() => _resp(status, body, headers: headers)),
  );
  try {
    await source.lookupUser('alguien');
  } on CloudSourceException catch (e) {
    return e;
  }
  fail('debía lanzar');
}

void main() {
  final langs = <String, AppLocalizations>{'es': AppLocalizationsEs(), 'en': AppLocalizationsEn()};

  group('descargas: un mensaje limpio por código HTTP', () {
    final cases = <String, ({int status, Object body, Map<String, String>? headers})>{
      '400': (status: 400, body: {'detail': 'URL no válida'}, headers: null),
      '401': (status: 401, body: {'detail': 'No autorizado'}, headers: null),
      '403': (status: 403, body: {'detail': 'Verificá tu correo'}, headers: null),
      '404': (status: 404, body: {'detail': 'Video unavailable'}, headers: null),
      '413': (status: 413, body: {'detail': 'Cuerpo demasiado grande'}, headers: null),
      '415': (status: 415, body: {'detail': 'sin audio'}, headers: null),
      '422': (status: 422, body: {'detail': 'Texto no válido'}, headers: null),
      '422 song_too_long': (status: 422, body: {'detail': 'x', 'reason': 'song_too_long'}, headers: null),
      '429 cola llena': (status: 429, body: {'detail': 'El servidor está ocupado'}, headers: {'retry-after': '5'}),
      '429 limite': (status: 429, body: {'detail': 'Demasiadas peticiones'}, headers: {'retry-after': '120'}),
      '429 sin retry-after': (status: 429, body: {'detail': 'x'}, headers: null),
      '429 cupo diario': (
        status: 429,
        body: {'detail': 'Llegaste a tu cupo diario de 50 canciones.', 'reason': 'daily_song_quota'},
        headers: {'retry-after': '3600'},
      ),
      '500': (status: 500, body: {'detail': 'Error interno'}, headers: null),
      '502': (status: 502, body: {'detail': 'yt-dlp: ERROR_EXTRACT'}, headers: null),
      '503 antibot': (status: 503, body: {'detail': "Sign in to confirm you're not a bot"}, headers: null),
      '503 auth': (status: 503, body: {'detail': 'No se pudo verificar la sesion'}, headers: {'retry-after': '5'}),
      '504': (status: 504, body: '<html>Gateway Timeout</html>', headers: null),
    };
    for (final entry in cases.entries) {
      test('HTTP ${entry.key}', () async {
        final error = await _downloadError(entry.value.status, entry.value.body, headers: entry.value.headers);
        for (final lang in langs.entries) {
          final f = localizedFriendlyError(lang.value, error);
          _expectClean(f.message, reason: '${entry.key}/${lang.key}');
          expect(f.code, startsWith('E-DL-'));
          expect(f.message.contains('detail'), isFalse);
        }
        _expectClean(error.userMessage, reason: '${entry.key}/userMessage');
      });
    }

    test('503 con Retry-After es servicio no disponible; sin él, anti-bot', () async {
      expect((await _downloadError(503, {'detail': 'x'}, headers: {'retry-after': '5'})).kind,
          DownloadSourceErrorKind.serviceUnavailable);
      expect((await _downloadError(503, {'detail': 'x'})).kind, DownloadSourceErrorKind.antiBotBlocked);
    });

    test('429 sin razón dice que el servidor está ocupado', () async {
      final error = await _downloadError(429, {'detail': 'x'}, headers: {'retry-after': '5'});
      expect(localizedFriendlyError(AppLocalizationsEs(), error).message, contains('ocupado'));
      expect(localizedFriendlyError(AppLocalizationsEn(), error).message, contains('busy'));
    });

    test('413 se trata como entrada inválida', () async {
      final error = await _downloadError(413, {'detail': 'x'});
      expect(error.kind, DownloadSourceErrorKind.badRequest);
    });

    test('el detail del servidor nunca llega al texto', () async {
      final error = await _downloadError(404, {'detail': 'SECRETO_DEL_SERVIDOR'});
      for (final l in langs.values) {
        expect(localizedFriendlyError(l, error).message.contains('SECRETO'), isFalse);
      }
    });

    test('todos los tipos tienen texto limpio en los dos idiomas', () {
      for (final kind in DownloadSourceErrorKind.values) {
        for (final lang in langs.entries) {
          _expectClean(
            localizedDownloadMessage(lang.value, kind, serverText: 'texto {raw} Exception', retryAfterSeconds: 120),
            reason: '$kind/${lang.key}',
          );
        }
        _expectClean(downloadErrorMessage(kind), reason: '$kind');
      }
    });
  });

  group('nube: un mensaje limpio por código HTTP', () {
    final cases = <String, ({int status, Object body, Map<String, String>? headers})>{
      '400': (status: 400, body: {'detail': 'Sólo letras minúsculas'}, headers: null),
      '401': (status: 401, body: {'detail': 'x'}, headers: null),
      '403': (status: 403, body: {'detail': 'x'}, headers: null),
      '404': (status: 404, body: {'detail': 'No encontrado'}, headers: null),
      '409': (status: 409, body: {'detail': 'Ese nombre ya está en uso'}, headers: null),
      '413': (status: 413, body: {'detail': 'Biblioteca demasiado grande'}, headers: null),
      '422': (status: 422, body: {'detail': [{'loc': ['body'], 'msg': 'x'}]}, headers: null),
      '428': (status: 428, body: {'detail': 'x'}, headers: null),
      '429': (status: 429, body: {'detail': 'Demasiadas peticiones'}, headers: {'retry-after': '10'}),
      '500': (status: 500, body: {'detail': 'Error interno'}, headers: null),
      '502': (status: 502, body: '<html>Bad Gateway</html>', headers: null),
      '503': (status: 503, body: {'detail': 'x'}, headers: {'retry-after': '5'}),
    };
    for (final entry in cases.entries) {
      test('HTTP ${entry.key}', () async {
        final error = await _cloudError(entry.value.status, entry.value.body, headers: entry.value.headers);
        for (final lang in langs.entries) {
          final f = localizedFriendlyError(lang.value, error);
          _expectClean(f.message, reason: '${entry.key}/${lang.key}');
          expect(f.code, startsWith('E-CL-'));
        }
        _expectClean(error.userMessage, reason: '${entry.key}/userMessage');
      });
    }

    test('503 es servicio no disponible y 500 es problema del servidor', () async {
      expect((await _cloudError(503, {'detail': 'x'})).kind, CloudSourceErrorKind.serviceUnavailable);
      expect((await _cloudError(500, {'detail': 'x'})).kind, CloudSourceErrorKind.serverError);
    });

    test('un 2xx con forma inesperada da un mensaje genérico claro', () async {
      final source = HeardyCloudSource(
        baseUrl: () => 'http://servidor:8080',
        authToken: () async => 'token',
        clientFactory: () => _FakeClient(() => _resp(200, [1, 2])),
      );
      try {
        await source.lookupUser('alguien');
        fail('debía lanzar');
      } on CloudSourceException catch (e) {
        for (final l in langs.values) {
          _expectClean(localizedFriendlyError(l, e).message);
        }
      }
    });

    test('textos fijos conocidos se traducen; otros no se muestran', () async {
      final taken = await _cloudError(409, {'detail': 'Ese nombre ya está en uso'});
      expect(localizedFriendlyError(AppLocalizationsEn(), taken).message, contains('taken'));
      final other = await _cloudError(409, {'detail': 'texto-desconocido-del-servidor'});
      expect(localizedFriendlyError(AppLocalizationsEs(), other).message.contains('desconocido'), isFalse);
    });

    test('todos los tipos tienen texto limpio en los dos idiomas', () {
      for (final kind in CloudSourceErrorKind.values) {
        for (final lang in langs.entries) {
          _expectClean(
            localizedCloudMessage(lang.value, kind, 'raw {x} Exception', retryAfterSeconds: 10),
            reason: '$kind/${lang.key}',
          );
        }
        _expectClean(cloudErrorMessage(kind, 'raw'), reason: '$kind');
      }
    });
  });

  group('sincronización y genéricos', () {
    test('cada paso con cada tipo de error es limpio', () {
      for (final step in ['cuenta', 'historial', 'historial-nuevo', 'biblioteca', 'presencia', 'otro']) {
        for (final kind in CloudSourceErrorKind.values) {
          for (final lang in langs.entries) {
            final f = localizedSyncStepError(lang.value, step, CloudSourceException(kind, 'raw {x}', statusCode: 500));
            _expectClean(f.message, reason: '$step/$kind/${lang.key}');
          }
        }
        for (final lang in langs.entries) {
          _expectClean(localizedSyncStepError(lang.value, step, StateError('boom')).message);
          _expectClean(localizedSyncStepError(lang.value, step, const FormatException('x')).message);
        }
      }
    });

    test('un TypeError o una excepción desconocida no se filtra', () {
      for (final lang in langs.values) {
        final f = localizedFriendlyError(lang, TypeError());
        _expectClean(f.message);
      }
    });
  });

  group('reason estable del servidor', () {
    const retry5 = {'retry-after': '5'};
    void expectBoth(Object error, String es, String en) {
      final msgEs = localizedFriendlyError(AppLocalizationsEs(), error).message;
      final msgEn = localizedFriendlyError(AppLocalizationsEn(), error).message;
      _expectClean(msgEs);
      _expectClean(msgEn);
      expect(msgEs, contains(es));
      expect(msgEn, contains(en));
    }

    test('429 busy y rate_limited tienen mensajes distintos', () async {
      final busy = await _downloadError(429, {'detail': 'x', 'reason': 'busy'}, headers: retry5);
      final limited = await _downloadError(429, {'detail': 'x', 'reason': 'rate_limited'}, headers: retry5);
      expect(busy.kind, DownloadSourceErrorKind.quotaExceeded);
      expect(limited.kind, DownloadSourceErrorKind.quotaExceeded);
      expectBoth(busy, 'ocupado', 'busy');
      expectBoth(limited, 'demasiadas acciones', 'too many');
      expect(limited.userMessage, contains('demasiadas acciones'));
    });

    test('503 antibot, auth_unavailable y not_configured se distinguen', () async {
      final antibot = await _downloadError(503, {'detail': 'x', 'reason': 'antibot'}, headers: retry5);
      final auth = await _downloadError(503, {'detail': 'x', 'reason': 'auth_unavailable'}, headers: retry5);
      final notConfigured = await _downloadError(503, {'detail': 'x', 'reason': 'not_configured'});
      expect(antibot.kind, DownloadSourceErrorKind.antiBotBlocked);
      expect(auth.kind, DownloadSourceErrorKind.serviceUnavailable);
      expect(notConfigured.kind, DownloadSourceErrorKind.serviceUnavailable);
      expectBoth(antibot, 'YouTube', 'YouTube');
      expectBoth(auth, 'sesión', 'session');
      expectBoth(notConfigured, 'no está listo', "isn't ready");
    });

    test('sin reason se conserva la clasificación anterior', () async {
      expect((await _downloadError(503, {'detail': 'x'}, headers: retry5)).kind,
          DownloadSourceErrorKind.serviceUnavailable);
      expect((await _downloadError(503, {'detail': 'x'})).kind, DownloadSourceErrorKind.antiBotBlocked);
      expectBoth(await _downloadError(429, {'detail': 'x'}, headers: retry5), 'ocupado', 'busy');
    });

    test('nube: rate_limited, busy y 503 por reason', () async {
      expectBoth(await _cloudError(429, {'detail': 'x', 'reason': 'rate_limited'}, headers: retry5),
          'demasiadas acciones', 'too many');
      expectBoth(await _cloudError(429, {'detail': 'x', 'reason': 'busy'}, headers: retry5), 'ocupado', 'busy');
      expectBoth(await _cloudError(503, {'detail': 'x', 'reason': 'auth_unavailable'}, headers: retry5),
          'sesión', 'session');
      expectBoth(await _cloudError(503, {'detail': 'x', 'reason': 'not_configured'}), 'no está listo', "isn't ready");
    });

    test('nube: textos fijos por reason, aunque el detail cambie', () async {
      final cases = <(int, String, String, String)>[
        (409, 'username_taken', 'en uso', 'taken'),
        (400, 'username_reserved', 'reservado', 'reserved'),
        (409, 'already_friends', 'amigos', 'friends'),
        (429, 'friends_limit', 'máximo de amigos', 'friend limit'),
        (429, 'requests_limit', 'pendientes', 'pending'),
        (400, 'cannot_add_self', 'agregarte', 'yourself'),
      ];
      for (final (status, reason, es, en) in cases) {
        final error = await _cloudError(status, {'detail': 'texto distinto', 'reason': reason}, headers: retry5);
        expectBoth(error, es, en);
      }
    });

    test('textos fijos de Spotify y de playlist duplicada salen en el idioma', () {
      for (final code in ['E-SP-URL', 'E-SP-DATA', 'E-SP-TYPE', 'E-SP-FMT', 'E-SP-403', 'E-PL-DUP']) {
        final error = FriendlyException('texto fijo en español', code);
        final es = localizedFriendlyError(AppLocalizationsEs(), error);
        final en = localizedFriendlyError(AppLocalizationsEn(), error);
        _expectClean(es.message, reason: code);
        _expectClean(en.message, reason: code);
        expect(es.message, isNot(equals(en.message)), reason: code);
        expect(en.code, code);
      }
    });
  });
}
