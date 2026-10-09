/// Qué hay que resolver antes de mostrar o accionar pistas remotas.
enum RemoteAccessGate { ok, noServer, needsLogin }

/// Descargar/escuchar exige servidor configurado y sesión; el resto de la app
/// no, así que cada pantalla remota consulta esto en vez de ser un gate global.
RemoteAccessGate remoteAccessGate({required bool hasServer, required bool isSignedIn}) {
  if (!hasServer) return RemoteAccessGate.noServer;
  if (!isSignedIn) return RemoteAccessGate.needsLogin;
  return RemoteAccessGate.ok;
}

/// mm:ss, no `AppTheme.formatDuration`: ése es para la duración TOTAL de una
/// playlist ("3h 20m"), no para una pista suelta.
String formatTrackDuration(int seconds) {
  final mins = seconds ~/ 60;
  final secs = seconds % 60;
  return '$mins:${secs.toString().padLeft(2, '0')}';
}
