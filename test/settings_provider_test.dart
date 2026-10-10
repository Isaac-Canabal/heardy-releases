// El servidor de descargas ya no se configura desde la app: su dirección va
// compilada en el binario (OfficialServer) — la autenticación, desde la Fase
// 2 del plan de seguridad, es una cuenta de Firebase (HeardyAuthProvider), no una
// clave que este provider pudiera exponer. Lo que estos tests cubren es que
// la dirección se cumpla de verdad y, sobre todo, que una instalación que
// venía de una versión anterior —cuando el servidor SÍ era editable— no se
// quede clavada apuntando a un servidor que ya no existe.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:heardy/providers/explore_provider.dart';
import 'package:heardy/providers/settings_provider.dart';
import 'package:heardy/services/official_server.dart';

Future<void> _waitLoaded(SettingsProvider settings) async {
  for (var i = 0; i < 50 && !settings.isLoaded; i++) {
    await Future.delayed(const Duration(milliseconds: 1));
  }
  expect(settings.isLoaded, isTrue, reason: 'SettingsProvider no terminó de cargar a tiempo');
}

void main() {
  group('servidor fijo', () {
    test('sin nada guardado, apunta al servidor oficial', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider();
      await _waitLoaded(settings);

      expect(settings.downloadServerUrl, OfficialServer.url);
      expect(settings.hasDownloadServer, isTrue,
          reason: 'descargar no debe requerir configuración previa');
    });

    test('un servidor propio guardado por una versión anterior se ignora', () async {
      // El caso que importa: sin UI que lo edite, respetar este valor dejaría
      // al usuario sin descargas y sin forma de volver desde dentro de la app.
      SharedPreferences.setMockInitialValues({
        'download_server_url': 'http://servidor-viejo-que-ya-no-existe:8080',
        'download_server_api_key': 'clave-vieja',
      });
      final settings = SettingsProvider();
      await _waitLoaded(settings);

      expect(settings.downloadServerUrl, OfficialServer.url);
    });

    test('esa configuración vieja además se borra, no sólo se ignora', () async {
      SharedPreferences.setMockInitialValues({
        'download_server_url': 'http://servidor-viejo-que-ya-no-existe:8080',
        'download_server_api_key': 'clave-vieja',
      });
      final settings = SettingsProvider();
      await _waitLoaded(settings);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('download_server_url'), isNull);
      expect(prefs.getString('download_server_api_key'), isNull,
          reason: 'una clave de API huérfana no debe seguir en disco');
    });
  });

  group('personalizar Explorar', () {
    test('por defecto nada está oculto y el país es automático', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider();
      await _waitLoaded(settings);

      expect(settings.exploreHiddenShelves, isEmpty);
      expect(settings.exploreCountry, isNull);
    });

    test('ocultar y mostrar una sección se persiste', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider();
      await _waitLoaded(settings);

      await settings.setExploreShelfHidden(ExploreShelfId.charts, true);
      await settings.setExploreShelfHidden(ExploreShelfId.radio, true);
      await settings.setExploreShelfHidden(ExploreShelfId.radio, false);
      expect(settings.exploreHiddenShelves, {ExploreShelfId.charts});

      final reloaded = SettingsProvider();
      await _waitLoaded(reloaded);
      expect(reloaded.exploreHiddenShelves, {ExploreShelfId.charts});

      await reloaded.showAllExploreShelves();
      expect(reloaded.exploreHiddenShelves, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('explore_hidden_shelves') ?? const [], isEmpty);
    });

    test('el país se normaliza, se persiste y null vuelve a automático', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider();
      await _waitLoaded(settings);

      await settings.setExploreCountry('mx');
      expect(settings.exploreCountry, 'MX');
      await settings.setExploreCountry('ZZ');
      expect(settings.exploreCountry, isNull);

      await settings.setExploreCountry('ES');
      final reloaded = SettingsProvider();
      await _waitLoaded(reloaded);
      expect(reloaded.exploreCountry, 'ES');

      await reloaded.setExploreCountry(null);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('explore_country'), isNull);
    });

    test('valores guardados corruptos se ignoran', () async {
      SharedPreferences.setMockInitialValues({
        'explore_hidden_shelves': ['moods', 'basura'],
        'explore_country': 'ZZZ',
      });
      final settings = SettingsProvider();
      await _waitLoaded(settings);

      expect(settings.exploreHiddenShelves, {ExploreShelfId.moods});
      expect(settings.exploreCountry, isNull);
    });
  });

  group('color dinámico en Reproduciendo ahora', () {
    test('viene activado por defecto', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider();
      await _waitLoaded(settings);

      expect(settings.dynamicNowPlayingColor, isTrue);
    });

    test('se persiste y se recupera en una instancia nueva', () async {
      SharedPreferences.setMockInitialValues({});
      final a = SettingsProvider();
      await _waitLoaded(a);
      await a.setDynamicNowPlayingColor(false);
      expect(a.dynamicNowPlayingColor, isFalse);

      final b = SettingsProvider();
      await _waitLoaded(b);
      expect(b.dynamicNowPlayingColor, isFalse);
    });
  });

  group('opciones de audio', () {
    test('vienen desactivadas por defecto', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsProvider();
      await _waitLoaded(settings);

      expect(settings.normalizeVolume, isFalse);
      expect(settings.skipSilence, isFalse);
      expect(settings.trackFade, isFalse);
    });

    test('se persisten y se recuperan en una instancia nueva', () async {
      SharedPreferences.setMockInitialValues({});
      final a = SettingsProvider();
      await _waitLoaded(a);
      await a.setNormalizeVolume(true);
      await a.setSkipSilence(true);
      await a.setTrackFade(true);

      final b = SettingsProvider();
      await _waitLoaded(b);
      expect(b.normalizeVolume, isTrue);
      expect(b.skipSilence, isTrue);
      expect(b.trackFade, isTrue);
    });
  });
}
