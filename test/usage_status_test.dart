import 'package:flutter_test/flutter_test.dart';

import 'package:heardy/services/download_source.dart';

void main() {
  group('UsageStatus', () {
    test('modo dia: sin period sigue funcionando como antes', () {
      final s = UsageStatus.fromJson({'usedToday': 4, 'dailyLimit': 10});
      expect(s.isMonthly, isFalse);
      expect(s.remaining, 6);
      expect(s.limit, 10);
    });

    test('modo mes: usa usedThisMonth y monthlyLimit', () {
      final s = UsageStatus.fromJson({
        'period': 'month',
        'usedThisMonth': 30,
        'monthlyLimit': 100,
        'usedToday': 0,
        'dailyLimit': 0,
      });
      expect(s.isMonthly, isTrue);
      expect(s.isEnabled, isTrue);
      expect(s.remaining, 70);
      expect(s.limit, 100);
    });

    test('modo mes con limite 0 esta apagado', () {
      final s = UsageStatus.fromJson({'period': 'month', 'monthlyLimit': 0});
      expect(s.isEnabled, isFalse);
      expect(s.remaining, 0);
    });

    test('remaining nunca es negativo', () {
      final s = UsageStatus.fromJson({'period': 'month', 'usedThisMonth': 9, 'monthlyLimit': 5});
      expect(s.remaining, 0);
    });
  });
}
