import 'dart:convert';

import 'package:http/http.dart' as http;
import 'app_log.dart';

/// Lo que hace falta de un release de GitHub para mostrar la notificación:
/// versión, dónde bajarla, y el texto que el usuario escribió al publicarlo.
class AppUpdateInfo {
  final String tag;
  final String name;
  final String htmlUrl;
  final String body;

  const AppUpdateInfo({
    required this.tag,
    required this.name,
    required this.htmlUrl,
    required this.body,
  });

  factory AppUpdateInfo.fromJson(Map<String, dynamic> json) => AppUpdateInfo(
        tag: (json['tag_name'] ?? '').toString(),
        name: (json['name'] ?? json['tag_name'] ?? '').toString(),
        htmlUrl: (json['html_url'] ?? '').toString(),
        body: (json['body'] ?? '').toString(),
      );
}

/// El cuerpo de un release de GitHub llega como Markdown; la tarjeta de
/// notificaciones lo pinta como texto plano: se quitan encabezados, énfasis y
/// comillas invertidas, y las viñetas pasan a «•». No recorta líneas.
String releaseNotesToPlainText(String markdown) {
  final lines = markdown.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
  return lines.map((raw) {
    var line = raw.trimRight();
    line = line.replaceFirst(RegExp(r'^\s{0,3}#{1,6}\s+'), '');
    line = line.replaceFirstMapped(RegExp(r'^(\s*)[-*+]\s+'), (m) => '${m[1]}• ');
    return line.replaceAll('`', '').replaceAll('**', '').replaceAll('__', '');
  }).join('\n').trim();
}

/// Único punto donde este apartado sabe que "el repositorio" vive en GitHub
/// — igual que `DownloadSource`/`CloudSource`, la app nunca habla con el
/// proveedor externo directamente desde una pantalla.
abstract class AppUpdateSource {
  /// `null` si no hay ningún release publicado todavía, o si la consulta
  /// falla (sin red, límite de tasa de la API sin autenticar, etc.) — nunca
  /// una excepción: comprobar la versión es una mejora, no algo de lo que el
  /// resto de la app dependa.
  Future<AppUpdateInfo?> getLatestRelease();
}

/// Repo de sólo binarios (`Isaac-Canabal/heardy-releases`), separado del
/// código fuente a propósito: permite que el repo con el código se ponga en
/// privado (menos exposición pública de cómo se esquivan las protecciones
/// anti-bot de YouTube) sin dejar de tener un lugar público donde alojar los
/// releases — ver las notas de trabajo locales para el porqué completo.
const String _githubRepo = 'Isaac-Canabal/heardy-releases';

/// El nombre exacto del binario que cada plataforma sube a un release de
/// GitHub — mismo convenio que ya usan `web/src/content/downloads.ts` (el
/// botón "Descargar" del sitio) y `windows/installer/heardy.iss`: **siempre
/// este nombre, sin sufijo de versión**, así el enlace de descarga directa
/// no cambia de un release al siguiente. `isAndroid` se recibe en vez de
/// leerse con `Platform.isAndroid` acá adentro para que esto sea una función
/// pura, comprobable con `flutter test` para las dos ramas — el host de test
/// siempre reporta como no-Android (ver `library_storage.dart`).
String releaseAssetFileName({required bool isAndroid}) =>
    isAndroid ? 'Heardy.apk' : 'Heardy-Setup.exe';

/// El enlace de descarga directa del binario de esta plataforma para un tag
/// de release dado (p. ej. `v1.1.2`).
String releaseAssetDownloadUrl(String tag, {required bool isAndroid}) =>
    isValidReleaseTag(tag)
        ? 'https://github.com/$_githubRepo/releases/download/$tag/${releaseAssetFileName(isAndroid: isAndroid)}'
        : '';

final RegExp _releaseTagPattern = RegExp(r'^v\d+\.\d+\.\d+$');

bool isValidReleaseTag(String tag) => _releaseTagPattern.hasMatch(tag);

const Set<String> _allowedExternalHosts = {
  'github.com',
  'heardy.vainastech.workers.dev',
};

/// `null` si [url] no es `https` hacia uno de los hosts conocidos de
/// releases/sitio; quien lo llame simplemente no abre nada.
Uri? safeExternalUri(String? url) {
  if (url == null || url.isEmpty) return null;
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme != 'https') return null;
  if (!_allowedExternalHosts.contains(uri.host.toLowerCase())) return null;
  if (uri.userInfo.isNotEmpty) return null;
  return uri;
}

/// El sitio público de Heardy — mismo dominio que `web/src/content/site.ts`
/// (`site.url`, documentado ahí como el dominio público para metadatos
/// OpenGraph, así que no es sensible). Un botón alternativo al enlace
/// directo del asset, para quien prefiera pasar por la página en vez de
/// bajar un binario a ciegas desde una notificación.
const String heardyWebsiteUrl = 'https://heardy.vainastech.workers.dev';

/// La API pública de GitHub Releases, sin autenticar (60 peticiones/hora por
/// IP de sobra para una consulta por arranque en frío). **Para que esto
/// avise de algo, cada versión que se quiera anunciar necesita un GitHub
/// Release con tag `vX.Y.Z` publicado** en `_githubRepo` — sin eso no hay
/// nada que comparar y `getLatestRelease()` devuelve `null` sin más.
class GithubAppUpdateSource implements AppUpdateSource {
  static const _url =
      'https://api.github.com/repos/$_githubRepo/releases/latest';

  final http.Client Function() _clientFactory;

  GithubAppUpdateSource({http.Client Function()? clientFactory})
      : _clientFactory = clientFactory ?? (() => http.Client());

  @override
  Future<AppUpdateInfo?> getLatestRelease() async {
    final client = _clientFactory();
    try {
      final response = await client
          .get(Uri.parse(_url), headers: {'Accept': 'application/vnd.github+json'})
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return null;
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final info = AppUpdateInfo.fromJson(json);
      return info.tag.isEmpty ? null : info;
    } catch (e) {
      appLog('GithubAppUpdateSource: no se pudo consultar el último release: $e');
      return null;
    } finally {
      client.close();
    }
  }
}
