import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:heardy/services/download_source.dart';
import 'package:heardy/services/friendly_error.dart';
import 'package:heardy/services/ytdlp_server_source.dart';
import 'package:http/http.dart' as http;

class _Client extends http.BaseClient {
  _Client(this._respond);
  final http.StreamedResponse Function() _respond;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async => _respond();
}

Future<DownloadSourceException> _error(int status, Object body) async {
  final bytes = utf8.encode(jsonEncode(body));
  final source = YtdlpServerSource(
    baseUrl: () => 'http://servidor:8080',
    authToken: () async => 'token',
    clientFactory: () => _Client(() => http.StreamedResponse(
          Stream.value(bytes),
          status,
          contentLength: bytes.length,
          headers: {'content-type': 'application/json'},
        )),
  );
  try {
    await source.resolve('https://youtu.be/abcdefghi01');
  } on DownloadSourceException catch (e) {
    return e;
  }
  fail('debía lanzar');
}

void main() {
  test('451 blocked_legal es un fallo permanente propio', () async {
    final e = await _error(451, {'detail': 'Contenido no disponible', 'reason': 'blocked_legal'});
    expect(e.kind, DownloadSourceErrorKind.blockedLegal);
    expect(e.isRetryable, isFalse);
    expect(e.code, 'E-DL-LEGAL-451');
  });

  test('el mensaje es fijo y nunca muestra el detail del servidor', () async {
    final e = await _error(451, {'detail': 'Reclamante X SECRETO', 'reason': 'blocked_legal'});
    expect(e.userMessage, 'Este contenido no está disponible por una reclamación de derechos de autor.');
    expect(e.userMessage, isNot(contains('SECRETO')));
    expect(e.reportMessage, contains('E-DL-LEGAL-451'));
  });

  test('un 404 sigue siendo notFound, no blockedLegal', () async {
    final e = await _error(404, {'detail': 'x'});
    expect(e.kind, DownloadSourceErrorKind.notFound);
  });

  test('downloadErrorCode cubre blockedLegal', () {
    expect(downloadErrorCode(DownloadSourceErrorKind.blockedLegal, statusCode: 451), 'E-DL-LEGAL-451');
  });
}
