/// Identificador visible de qué código trae este binario en concreto —
/// se bumpea a mano en cada build de prueba durante W7/W8 del plan de
/// escritorio, justamente porque más de una vez costó saber si un `.exe`
/// probado era el último o uno viejo con antivirus de por medio en el
/// empaquetado. Mostrado en `SyncStatusScreen` para que decir "veo tal
/// mensaje" sea inequívoco sobre qué versión lo generó. Se puede borrar
/// tranquilamente cuando esta fase de verificación manual termine.
const String buildMarker = '2026-09-06_1332';
