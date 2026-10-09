/// El servidor oficial mantenido por el proyecto: el modo por defecto para
/// que el usuario promedio nunca tenga que configurar nada. Ver
/// docs/arquitectura_servidor_hibrido.md, secciones 3 y 4.
library;

/// URL y clave por defecto que usa [SettingsProvider] mientras el usuario no
/// haya elegido explícitamente un servidor propio en Ajustes avanzados.
///
/// La URL del servidor oficial es pública (es sólo un hostname de Render, un
/// servicio compartido) y puede vivir en el código sin problema. **Ojo con
/// esto si el servidor vuelve a ser casero:** un hostname de Tailscale Funnel
/// nombra una máquina personal, y este repositorio es público — ese caso va
/// por `--dart-define`, nunca como `defaultValue` acá.
///
/// **Actualización 2026-08-24, Fase 2 del plan de seguridad: ya no hay clave
/// compilada (cierra el hallazgo A1).** `apiKey` existió acá y viajaba
/// idéntica dentro de cada APK repartido — cualquiera podía sacarla con
/// `strings` sobre el binario, porque `minifyEnabled` ni siquiera la ofuscaba
/// del todo. La reemplaza una cuenta real por persona vía Firebase Auth
/// (`HeardyAuthProvider`, `lib/screens/auth/login_screen.dart`): `YtdlpServerSource`
/// ahora manda `Authorization: Bearer <token de Firebase>`, nunca una clave
/// fija. Sin sesión, las llamadas al servidor simplemente salen sin
/// autenticación y el servidor las rechaza — comportamiento correcto, no un
/// caso a manejar aparte.
///
/// **Actualización 2026-08-22:** el servidor oficial pasó a Render
/// (`heardy.onrender.com`), con cookies de sesión de YouTube
/// (`HEARDY_COOKIES_FILE`) para esquivar el bloqueo anti-bot que antes hacía
/// inviable una IP de datacenter. Ya no depende de que ningún PC concreto
/// esté encendido.
///
/// **Actualización 2026-08-24: esta dirección ya no se puede cambiar desde
/// la app.** Antes se podía pisar en "Ajustes avanzados" y quedaba guardada
/// en `SharedPreferences`; eso desapareció (ver
/// `SettingsProvider.downloadServerUrl`), porque el servidor oficial es uno
/// solo y estable, y lo único que conseguía un campo editable era que
/// alguien se rompiera las descargas sin saber volver. Para apuntar a otro
/// servidor —el flujo de desarrollo contra `server/` en local— se usa
/// `--dart-define=HEARDY_OFFICIAL_SERVER_URL=...` en tiempo de build, que es
/// donde corresponde. Por eso ambos valores siguen siendo
/// `String.fromEnvironment` y no constantes literales.
class OfficialServer {
  const OfficialServer._();

  static const String url = String.fromEnvironment(
    'HEARDY_OFFICIAL_SERVER_URL',
    defaultValue: 'https://heardy.onrender.com',
  );

  /// Servidores de respaldo, separados por comas, que se usan en orden cuando
  /// el oficial agota su ancho de banda mensual. Sólo por `--dart-define`:
  /// vacío por defecto, y no se documenta ninguna dirección real acá.
  static const String _fallbackUrls = String.fromEnvironment('HEARDY_FALLBACK_SERVER_URLS');

  static List<String> get urls => [
        url,
        ..._fallbackUrls.split(',').map((u) => u.trim()).where((u) => u.isNotEmpty),
      ];
}
