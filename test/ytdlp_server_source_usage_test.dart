import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:heardy/services/download_source.dart';
import 'package:heardy/services/ytdlp_server_source.dart';

class _Client extends http.BaseClient {
  _Client(this.handler);
  final http.StreamedResponse Function() handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async => handler();
}

YtdlpServerSource _source(_Client c) => YtdlpServerSource(
      baseUrl: () => 'http://servidor:8080',
      authToken: () async => 't',
      clientFactory: () => c,
    );

void main() {
  test('429 monthly_song_quota es dailyQuotaExceeded con retryAfterSeconds', () async {
    final client = _Client(() => http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode({
            'detail': 'Llegaste a tu cupo mensual de 50 canciones.',
            'reason': 'monthly_song_quota',
            'period': 'month',
            'usedThisMonth': 50,
            'monthlyLimit': 50,
          }))),
          429,
          headers: {'retry-after': '7200'},
        ));
    await expectLater(
      _source(client).resolve('https://youtu.be/x'),
      throwsA(isA<DownloadSourceException>()
          .having((e) => e.kind, 'kind', DownloadSourceErrorKind.dailyQuotaExceeded)
          .having((e) => e.retryAfterSeconds, 'retryAfterSeconds', 7200)),
    );
  });

  test('usage() parsea el periodo mensual', () async {
    final client = _Client(() => http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode({
            'period': 'month',
            'usedThisMonth': 3,
            'monthlyLimit': 40,
            'usedToday': 0,
            'dailyLimit': 0,
          }))),
          200,
        ));
    final s = await _source(client).usage();
    expect(s.isMonthly, isTrue);
    expect(s.remaining, 37);
  });
}
