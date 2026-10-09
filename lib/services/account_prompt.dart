/// Decisión de si mostrar el popup de vinculación de cuenta, extraída como
/// función pura — mismo precedente que `missingPlaylistEntries()` (Etapa 6):
/// testeable sin `BuildContext`, sin providers, sin widgets.
///
/// Las cuatro condiciones, en orden (ver CLAUDE.md, "Cloud sync" y el
/// registro de la Etapa 16 B2):
/// 1. `loaded` — [SettingsProvider] ya terminó de cargar de
///    SharedPreferences; sin esto se leería el valor por defecto de
///    `accountPromptSeen` (false) en cada arranque y el popup reaparecería
///    para siempre.
/// 2. `!seen` — nunca se mostró antes, o el usuario no lo cerró todavía.
/// 3. `!signedIn` — quien ya inició sesión (aunque no haya verificado el
///    correo todavía) ya aceptó la invitación.
/// 4. `songCount > 0` — una instalación nueva sin canciones no ve nada, y
///    la marca no se pone: instalar → 0 canciones → silencio; importar 40
///    archivos → siguiente arranque → invitación una vez.
bool shouldShowAccountPrompt({
  required bool loaded,
  required bool seen,
  required bool signedIn,
  required int songCount,
}) {
  return loaded && !seen && !signedIn && songCount > 0;
}
