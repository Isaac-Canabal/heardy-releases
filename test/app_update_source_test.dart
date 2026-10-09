import 'package:flutter_test/flutter_test.dart';
import 'package:heardy/services/app_update_source.dart';

void main() {
  group('releaseAssetDownloadUrl', () {
    test('Android baja el APK', () {
      expect(
        releaseAssetDownloadUrl('v1.1.2', isAndroid: true),
        'https://github.com/Isaac-Canabal/heardy-releases/releases/download/v1.1.2/Heardy.apk',
      );
    });

    test('Windows baja el instalador', () {
      expect(
        releaseAssetDownloadUrl('v1.1.2', isAndroid: false),
        'https://github.com/Isaac-Canabal/heardy-releases/releases/download/v1.1.2/Heardy-Setup.exe',
      );
    });
  });

  group('isValidReleaseTag', () {
    test('acepta vX.Y.Z', () {
      expect(isValidReleaseTag('v1.1.2'), isTrue);
      expect(isValidReleaseTag('v10.0.123'), isTrue);
    });

    test('rechaza lo demás', () {
      for (final t in ['1.1.2', 'v1.1', 'v1.1.2-beta', 'v1.1.2/../x', '', 'v1.1.2\n', ' v1.1.2']) {
        expect(isValidReleaseTag(t), isFalse, reason: t);
      }
    });

    test('un tag inválido no produce enlace de descarga', () {
      expect(releaseAssetDownloadUrl('v1/../../x', isAndroid: true), '');
    });
  });

  group('safeExternalUri', () {
    test('acepta https hacia los hosts conocidos', () {
      expect(safeExternalUri('https://github.com/Isaac-Canabal/heardy-releases/releases/tag/v1.0.0'), isNotNull);
      expect(safeExternalUri(heardyWebsiteUrl), isNotNull);
    });

    test('rechaza otros esquemas, hosts y credenciales', () {
      for (final u in [
        'http://github.com/x',
        'https://evil.example/x',
        'https://github.com.evil.example/x',
        'https://user@github.com/x',
        'file:///c:/windows',
        'javascript:alert(1)',
        'intent://x#Intent;end',
        '',
        'no es url',
      ]) {
        expect(safeExternalUri(u), isNull, reason: u);
      }
      expect(safeExternalUri(null), isNull);
    });
  });
}
