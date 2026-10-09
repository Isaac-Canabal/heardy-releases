import 'package:flutter_test/flutter_test.dart';
import 'package:heardy/services/server_pool.dart';

void main() {
  group('looksLikeCapacityExhausted', () {
    test('503 con HTML de servicio suspendido', () {
      expect(
        looksLikeCapacityExhausted(503, {}, '<html><body>This service has been suspended</body></html>'),
        isTrue,
      );
    });

    test('cabecera de enrutamiento suspendido', () {
      expect(looksLikeCapacityExhausted(503, {'x-render-routing': 'suspend'}, ''), isTrue);
    });

    test('un 503 JSON de la propia API (anti-bot) no cuenta', () {
      expect(looksLikeCapacityExhausted(503, {}, '{"detail":"bloqueado suspended"}'), isFalse);
    });

    test('cualquier error HTML que diga "suspended" cuenta, sea cual sea el código', () {
      expect(looksLikeCapacityExhausted(404, {}, '<html>Service Suspended</html>'), isTrue);
      expect(looksLikeCapacityExhausted(402, {}, 'Service Suspended'), isTrue);
    });

    test('"bandwidth" en texto plano o de un error cualquiera no cuenta', () {
      expect(looksLikeCapacityExhausted(400, {}, 'bandwidth limit for this upload'), isFalse);
      expect(looksLikeCapacityExhausted(500, {}, 'Low bandwidth detected'), isFalse);
    });

    test('"bandwidth" en una página HTML del proxy sí cuenta', () {
      expect(
        looksLikeCapacityExhausted(503, {}, '<html><body>Bandwidth limit exceeded</body></html>'),
        isTrue,
      );
    });

    test('un 404 HTML corriente no cuenta', () {
      expect(looksLikeCapacityExhausted(404, {}, '<html>Not Found</html>'), isFalse);
    });
  });

  group('ServerPool', () {
    test('pasa al siguiente servidor y avisa sólo cuando todos se agotan', () {
      var now = DateTime.utc(2026, 9, 30, 12);
      final pool = ServerPool(['a', 'b'], now: () => now);

      expect(pool.current(), 'a');
      pool.markExhausted('a');
      expect(pool.current(), 'b');
      expect(pool.allExhaustedUntil.value, isNull);

      pool.markExhausted('b');
      expect(pool.current(), isNull);
      expect(pool.allExhaustedUntil.value, DateTime.utc(2026, 10, 1));
    });

    test('sondea un servidor agotado pasado el intervalo y se recupera', () {
      var now = DateTime.utc(2026, 9, 30, 12);
      final pool = ServerPool(['a'], now: () => now);
      pool.markExhausted('a');
      expect(pool.current(), isNull);

      now = now.add(ServerPool.probeInterval);
      expect(pool.current(), 'a');
      expect(pool.current(), isNull, reason: 'una sola sondeada por intervalo');

      pool.markHealthy('a');
      expect(pool.allExhaustedUntil.value, isNull);
      expect(pool.current(), 'a');
    });

    test('el reinicio del mes libera el servidor', () {
      var now = DateTime.utc(2026, 9, 30, 12);
      final pool = ServerPool(['a'], now: () => now);
      pool.markExhausted('a');
      now = DateTime.utc(2026, 10, 1);
      expect(pool.current(), 'a');
      expect(pool.allExhaustedUntil.value, isNull);
    });

    test('nextMonthStartUtc cruza el fin de año', () {
      expect(ServerPool.nextMonthStartUtc(DateTime.utc(2026, 12, 31)), DateTime.utc(2027, 1, 1));
    });
  });

  test('formatRemaining', () {
    expect(formatRemaining(const Duration(days: 12, hours: 4, minutes: 3)), '12 d 4 h');
    expect(formatRemaining(const Duration(hours: 5, minutes: 20)), '5 h 20 min');
    expect(formatRemaining(const Duration(minutes: 12)), '12 min');
    expect(formatRemaining(const Duration(seconds: 10)), '< 1 min');
  });
}
