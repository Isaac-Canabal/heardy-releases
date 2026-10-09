import 'package:flutter_test/flutter_test.dart';
import 'package:heardy/services/version_compare.dart';

void main() {
  group('isNewerVersion', () {
    test('mayor, menor y parche más altos cuentan como más nueva', () {
      expect(isNewerVersion('2.0.0', '1.9.9'), isTrue);
      expect(isNewerVersion('1.3.0', '1.2.9'), isTrue);
      expect(isNewerVersion('1.2.4', '1.2.3'), isTrue);
    });

    test('igual o más vieja no cuenta como más nueva', () {
      expect(isNewerVersion('1.2.3', '1.2.3'), isFalse);
      expect(isNewerVersion('1.2.2', '1.2.3'), isFalse);
      expect(isNewerVersion('0.9.9', '1.0.0'), isFalse);
    });

    test('el prefijo "v" y los sufijos de build/prerelease se ignoran', () {
      expect(isNewerVersion('v1.2.4', '1.2.3'), isTrue);
      expect(isNewerVersion('1.2.4-beta', '1.2.3+7'), isTrue);
      expect(isNewerVersion('1.2.3+9', '1.2.3+4'), isFalse); // el build no cuenta
    });

    test('una versión sin dígitos reconocibles nunca dispara la comparación', () {
      expect(isNewerVersion('latest', '1.2.3'), isFalse);
      expect(isNewerVersion('1.2.3', 'unknown'), isFalse);
      expect(isNewerVersion('', ''), isFalse);
    });
  });
}
