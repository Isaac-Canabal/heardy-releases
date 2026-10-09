import 'dart:async';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heardy/services/cloud_source.dart';
import 'package:heardy/services/download_source.dart';
import 'package:heardy/services/firebase_rest_auth.dart';
import 'package:heardy/services/friendly_error.dart';

const _forbidden = [
  'Exception',
  'runtimeType',
  'SocketException',
  'TimeoutException',
  '[historial]',
  '[cuenta]',
  '[biblioteca]',
  'HTTP',
  'statusCode',
  '[{',
  'EMAIL_EXISTS',
  'API_KEY_',
  'yt-dlp',
  '://',
  'C:\\',
  '/data/',
  'Traceback',
];

void expectClean(String text) {
  for (final bad in _forbidden) {
    expect(text.contains(bad), isFalse, reason: '"$text" contiene "$bad"');
  }
}

final _codeRe = RegExp(r'^E-[A-Z]{2,3}-[A-Z0-9-]+$');

const _hostile = [
  'SocketException: Failed host lookup: "x.onrender.com" (OS Error: No address, errno = 7)',
  'ERROR: [youtube] abc: Sign in to confirm you are not a bot',
  "[{loc: [body, url], msg: field required, type: missing}]",
  '#0  main (file:///C:/Dev/Heardy/lib/main.dart:10)\nTraceback (most recent call last)',
  'El servidor respondió 502: <html>',
  'http://10.0.0.1:8000/audio/abc',
  'EMAIL_EXISTS',
];

void main() {
  group('DownloadSourceException', () {
    test('todos los tipos dan mensaje y código válidos', () {
      for (final kind in DownloadSourceErrorKind.values) {
        final e = DownloadSourceException(kind, 'detalle', retryAfterSeconds: 120);
        expect(e.userMessage, isNotEmpty, reason: '$kind');
        expect(e.code, matches(_codeRe), reason: '$kind');
        expect(e.code, startsWith('E-DL-'));
        expectClean(e.userMessage);
        expectClean(e.code);
        expect(e.reportMessage, contains('Código: ${e.code}'));
      }
    });

    test('mensajes hostiles nunca se filtran', () {
      for (final kind in DownloadSourceErrorKind.values) {
        for (final raw in _hostile) {
          final e = DownloadSourceException(kind, raw, statusCode: 502);
          expectClean(e.userMessage);
          expectClean(e.code);
          expect(e.userMessage.contains('Failed host'), isFalse);
          expect(e.userMessage.contains('Sign in to confirm'), isFalse);
          expect(e.userMessage.contains('field required'), isFalse);
        }
      }
    });

    test('el código incluye el estado HTTP cuando se conoce', () {
      const e = DownloadSourceException(DownloadSourceErrorKind.extraction, 'x', statusCode: 502);
      expect(e.code, 'E-DL-EXT-502');
      const n = DownloadSourceException(DownloadSourceErrorKind.network, 'x');
      expect(n.code, 'E-DL-NET');
    });

    test('el texto del servidor sólo se muestra en los cupos', () {
      const daily = DownloadSourceException(
        DownloadSourceErrorKind.dailyQuotaExceeded,
        'Llegaste a tu cupo diario de 150 canciones. Volvé mañana.',
      );
      expect(daily.userMessage, contains('150'));
      expect(daily.userMessage, isNot(contains('Volvé')));
      expect(daily.userMessage, contains('Vuelve'));

      const ext = DownloadSourceException(DownloadSourceErrorKind.extraction, 'texto del servidor raro');
      expect(ext.userMessage, isNot(contains('texto del servidor raro')));
      const bad = DownloadSourceException(DownloadSourceErrorKind.badRequest, 'campo url requerido');
      expect(bad.userMessage, isNot(contains('campo url')));
    });

    test('un texto de cupo con basura técnica cae al mensaje fijo', () {
      const daily = DownloadSourceException(
        DownloadSourceErrorKind.dailyQuotaExceeded,
        "[{loc: x}] SocketException",
      );
      expectClean(daily.userMessage);
      expect(daily.userMessage, isNotEmpty);
    });

    test('canción demasiado larga es terminal', () {
      const e = DownloadSourceException(DownloadSourceErrorKind.songTooLong, 'x', statusCode: 422);
      expect(e.isRetryable, isFalse);
      expect(e.code, 'E-DL-LONG-422');
      expect(e.userMessage, contains('larga'));
    });

    test('notConfigured distingue carpeta de servidor sin filtrar el mensaje', () {
      const folder = DownloadSourceException(
        DownloadSourceErrorKind.notConfigured,
        'Elegí primero una carpeta de biblioteca en Ajustes',
      );
      expect(folder.userMessage, contains('carpeta'));
      const server = DownloadSourceException(DownloadSourceErrorKind.notConfigured, 'No hay servidor');
      expect(server.userMessage, contains('servidor'));
    });

    test('sin voseo en los mensajes fijos', () {
      for (final kind in DownloadSourceErrorKind.values) {
        final m = DownloadSourceException(kind, '', retryAfterSeconds: 30).userMessage;
        for (final voseo in ['Probá', 'Elegí', 'Intentá', 'Esperá', 'Volvé', 'Revisá']) {
          expect(m.contains(voseo), isFalse, reason: '$kind: $m');
        }
      }
    });
  });

  group('CloudSourceException', () {
    test('todos los tipos dan mensaje y código válidos', () {
      for (final kind in CloudSourceErrorKind.values) {
        final e = CloudSourceException(kind, 'detalle');
        expect(e.userMessage, isNotEmpty, reason: '$kind');
        expect(e.code, matches(_codeRe), reason: '$kind');
        expect(e.code, startsWith('E-CL-'));
        expectClean(e.userMessage);
        expectClean(e.code);
      }
    });

    test('mensajes hostiles nunca se filtran', () {
      for (final kind in CloudSourceErrorKind.values) {
        for (final raw in _hostile) {
          for (final status in [null, 400, 409, 422, 429, 500]) {
            final e = CloudSourceException(kind, raw, statusCode: status);
            expectClean(e.userMessage);
            expectClean(e.code);
          }
        }
      }
    });

    test('texto del servidor verbatim sólo en conflict, cupo y 400', () {
      expect(
        const CloudSourceException(CloudSourceErrorKind.conflict, 'Ese nombre ya está en uso', statusCode: 409)
            .userMessage,
        'Ese nombre ya está en uso',
      );
      expect(
        const CloudSourceException(CloudSourceErrorKind.quotaExceeded, 'Demasiadas solicitudes pendientes')
            .userMessage,
        contains('Demasiadas solicitudes pendientes'),
      );
      expect(
        const CloudSourceException(CloudSourceErrorKind.badRequest, 'Nombre demasiado corto', statusCode: 400)
            .userMessage,
        contains('Nombre demasiado corto'),
      );
      // 422/413: el detalle es una lista de campos, no un texto para personas.
      expect(
        const CloudSourceException(CloudSourceErrorKind.badRequest, 'Nombre demasiado corto', statusCode: 422)
            .userMessage,
        isNot(contains('Nombre demasiado corto')),
      );
      expect(
        const CloudSourceException(CloudSourceErrorKind.notFound, 'No encontrado').userMessage,
        isNot(equals('No encontrado')),
      );
      expect(
        const CloudSourceException(CloudSourceErrorKind.unauthorized, 'texto raro del servidor').userMessage,
        isNot(contains('texto raro')),
      );
    });

    test('conflicto de versión usa su propio mensaje', () {
      const e = CloudSourceException(
        CloudSourceErrorKind.conflict,
        '{reason: library_version_conflict}',
        statusCode: 409,
        isVersionConflict: true,
      );
      expectClean(e.userMessage);
      expect(e.userMessage, isNot(contains('reason')));
    });

    test('el código incluye el estado cuando se conoce', () {
      const e = CloudSourceException(CloudSourceErrorKind.network, 'x', statusCode: 500);
      expect(e.code, 'E-CL-NET-500');
    });
  });

  group('sync', () {
    test('el paso va sólo en el código', () {
      const steps = {
        'cuenta': 'CU',
        'historial': 'HI',
        'historial-nuevo': 'HN',
        'biblioteca': 'BI',
        'presencia': 'PR',
      };
      steps.forEach((step, short) {
        for (final kind in CloudSourceErrorKind.values) {
          final f = friendlySyncStepError(step, CloudSourceException(kind, 'X', statusCode: 500));
          expect(f.message, isNotEmpty);
          expectClean(f.message);
          expect(f.message.contains('['), isFalse);
          expect(f.code, startsWith('E-SY-$short-'));
          expect(f.code, matches(_codeRe));
        }
      });
    });

    test('errores no cloud no se filtran', () {
      for (final raw in _hostile) {
        final f = friendlySyncStepError('historial', StateError(raw));
        expectClean(f.message);
        expectClean(f.code);
        expect(f.code, startsWith('E-SY-HI-'));
      }
      final net = friendlySyncStepError('cuenta', const SocketException('Failed host lookup'));
      expect(net.message.contains('Failed'), isFalse);
      expect(net.code, 'E-SY-CU-NET');
    });
  });

  group('genérico', () {
    test('categoriza sin filtrar el texto crudo', () {
      for (final raw in _hostile) {
        for (final e in <Object>[
          Exception(raw),
          StateError(raw),
          SocketException(raw),
          TimeoutException(raw),
          FormatException(raw),
          FileSystemException(raw, 'C:\\Users\\x\\musica'),
          raw,
        ]) {
          final f = friendlyFromError(e);
          expectClean(f.message);
          expectClean(f.code);
          expect(f.code, matches(_codeRe));
          expect(f.message.contains('Failed host'), isFalse);
          expect(f.message.contains('Users'), isFalse);
        }
      }
    });

    test('FriendlyException conserva su mensaje y código', () {
      final f = friendlyFromError(const FriendlyException('Ya existe una playlist con ese nombre', 'E-PL-DUP'));
      expect(f.message, 'Ya existe una playlist con ese nombre');
      expect(f.code, 'E-PL-DUP');
    });

    test('delega en las excepciones tipadas', () {
      final f = friendlyFromError(const DownloadSourceException(DownloadSourceErrorKind.notFound, 'x', statusCode: 404));
      expect(f.code, 'E-DL-NF-404');
      final c = friendlyFromError(const CloudSourceException(CloudSourceErrorKind.network, 'x'));
      expect(c.code, 'E-CL-NET');
    });

    test('red: mensaje de conexión', () {
      final f = friendlyFromError(const SocketException('x'));
      expect(f.message, contains('conexión'));
      expect(f.code, 'E-GEN-NET');
    });

    test('el área se refleja en el código', () {
      final f = friendlyFromError(StateError('x'), area: 'FS');
      expect(f.code, startsWith('E-FS-'));
    });
  });

  group('autenticación', () {
    test('clasifica errores del SDK, REST y de red', () {
      expect(authErrorKindOf(FirebaseAuthException(code: 'network-request-failed')), AuthErrorKind.network);
      expect(authErrorKindOf(const FirebaseRestAuthException('NETWORK_REQUEST_FAILED')), AuthErrorKind.network);
      expect(authErrorKindOf(const SocketException('x')), AuthErrorKind.network);
      expect(authErrorKindOf(FirebaseAuthException(code: 'operation-not-allowed')), AuthErrorKind.operationNotAllowed);
      expect(authErrorKindOf(const FirebaseRestAuthException('OPERATION_NOT_ALLOWED')), AuthErrorKind.operationNotAllowed);
      expect(authErrorKindOf(FirebaseAuthException(code: 'requires-recent-login')), AuthErrorKind.requiresRecentLogin);
      expect(authErrorKindOf(const FirebaseRestAuthException('CREDENTIAL_TOO_OLD_LOGIN_AGAIN')),
          AuthErrorKind.requiresRecentLogin);
      expect(authErrorKindOf(const FirebaseRestAuthException('INVALID_ID_TOKEN')), AuthErrorKind.sessionExpired);
      expect(authErrorKindOf(const FirebaseRestAuthException('TOKEN_EXPIRED')), AuthErrorKind.sessionExpired);
      expect(authErrorKindOf(FirebaseAuthException(code: 'user-token-expired')), AuthErrorKind.sessionExpired);
      expect(authErrorKindOf(const FirebaseRestAuthException('EMAIL_EXISTS')), AuthErrorKind.emailInUse);
      expect(authErrorKindOf(FirebaseAuthException(code: 'weak-password')), AuthErrorKind.weakPassword);
      expect(authErrorKindOf(FirebaseAuthException(code: 'too-many-requests')), AuthErrorKind.tooManyRequests);
      expect(authErrorKindOf(StateError('API_KEY_ANDROID_APP_BLOCKED')), AuthErrorKind.appNotAuthorized);
      expect(authErrorKindOf(StateError('algo raro')), AuthErrorKind.generic);
    });

    test('cada tipo tiene un código válido', () {
      for (final kind in AuthErrorKind.values) {
        final code = authErrorCode(kind);
        expect(code, matches(_codeRe));
        expect(code, startsWith('E-AU-'));
      }
    });
  });

  group('tuteo y texto del servidor', () {
    test('convierte voseo habitual', () {
      expect(tuteo('Volvé mañana'), 'Vuelve mañana');
      expect(tuteo('Esperá a que se renueve'), 'Espera a que se renueve');
      expect(tuteo('Probá de nuevo'), 'Prueba de nuevo');
    });

    test('safeServerText descarta basura técnica', () {
      expect(safeServerText(null), isNull);
      expect(safeServerText(''), isNull);
      expect(safeServerText('sin detalle'), isNull);
      expect(safeServerText('[{loc: x}]'), isNull);
      expect(safeServerText('Failed with SocketException'), isNull);
      expect(safeServerText('ERROR: Sign in to confirm you are not a bot'), isNull);
      expect(safeServerText('Ese nombre ya está en uso'), 'Ese nombre ya está en uso');
    });
  });
}
