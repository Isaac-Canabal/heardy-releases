import 'app_update_source.dart';
import 'version_compare.dart';

/// Decisión pura de la puerta de actualización: la app queda bloqueada sólo
/// si la versión instalada es estrictamente menor que el último release
/// publicado que se llegó a ver. Cualquier valor vacío, nulo o que no sea un
/// tag `vX.Y.Z` jamás bloquea.
bool updateGateDecision({String? installedVersion, String? latestKnownTag}) {
  if (installedVersion == null || installedVersion.isEmpty) return false;
  if (latestKnownTag == null || !isValidReleaseTag(latestKnownTag)) return false;
  return isNewerVersion(latestKnownTag, installedVersion);
}
