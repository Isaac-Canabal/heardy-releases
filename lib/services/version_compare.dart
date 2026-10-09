/// Compara dos versiones "semver-ish" (`1.2.3`, opcionalmente con prefijo
/// `v` y sufijo de build tipo `+4` o `-beta`) sin depender de ningún paquete
/// de semver completo — acá sólo hace falta "¿A es más nueva que B?".
///
/// Función pura, sin red ni `BuildContext`, para poder probarla sin
/// necesidad de un doble de [AppUpdateSource].
bool isNewerVersion(String remoteTag, String localVersion) {
  final remote = _parse(remoteTag);
  final local = _parse(localVersion);
  if (remote == null || local == null) return false;

  for (var i = 0; i < 3; i++) {
    if (remote[i] != local[i]) return remote[i] > local[i];
  }
  return false;
}

/// `null` si no hay ni un dígito reconocible — una versión con forma rara no
/// debe compararse a ciegas, y mucho menos disparar una notificación.
List<int>? _parse(String raw) {
  var s = raw.trim();
  if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
  // Corta en el primer separador que no sea parte de "mayor.menor.parche"
  // (`+build`, `-beta`, etc.) — sólo importa el núcleo numérico.
  final core = s.split(RegExp(r'[+\-]')).first;
  final parts = core.split('.');
  if (parts.isEmpty) return null;

  final nums = <int>[];
  for (var i = 0; i < 3; i++) {
    final n = i < parts.length ? int.tryParse(parts[i]) : 0;
    if (n == null) return null;
    nums.add(n);
  }
  return nums;
}
