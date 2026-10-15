/// Interfaz abstracta hacia el backend de cuentas en la nube (Etapa 16):
/// cuenta, biblioteca/historial sincronizados, amigos, "escuchando ahora".
///
/// Una sola interfaz para las cinco cosas, no cinco — `download_source.dart`
/// lleva escrito "No la hagas crecer sin un segundo proveedor real que lo
/// justifique", y aquí aplica igual: [CloudSource] existe para poder
/// inyectar un doble en tests (ver CLAUDE.md, "Cloud sync"), no para
/// intercambiar proveedores. [HeardyCloudSource] es la única implementación
/// real.
library;

import 'friendly_error.dart';

enum CloudSourceErrorKind {
  /// Sin conexión/timeout — reintentable, nunca gasta el presupuesto de
  /// reintentos de quien llama.
  network,

  /// 401/403 — sesión ausente o token vencido.
  unauthorized,

  /// 404 — el nombre de usuario buscado no existe.
  notFound,

  /// 409 — nombre de usuario ocupado, o conflicto de versión de biblioteca
  /// (`library_version_conflict`, ver [CloudSourceException.isVersionConflict]).
  conflict,

  /// 429 con cuerpo — cupo diario agotado (búsquedas, solicitudes,
  /// subidas...). [CloudSourceException.retryAfterSeconds] cuando el
  /// servidor lo manda.
  quotaExceeded,

  /// 428 Precondition Required — la cuenta todavía no eligió nombre de
  /// usuario. Estado normal y duradero (E-5), no un error de verdad.
  needsUsername,

  /// 400/413/422 — payload rechazado (formato de nombre inválido, cuerpo
  /// demasiado grande, etc).
  badRequest,

  /// 503 — el servicio no puede atender ahora (p. ej. la verificación de
  /// sesión no responde). Temporal.
  serviceUnavailable,

  /// 500 u otro fallo inesperado del servidor.
  serverError,

  /// Todos los servidores se quedaron sin ancho de banda del mes.
  /// [CloudSourceException.message] ya trae el texto con el tiempo que falta.
  serverCapacityExhausted,
}

class CloudSourceException implements Exception {
  final CloudSourceErrorKind kind;
  final String message;
  final int? retryAfterSeconds;
  final bool isVersionConflict;

  /// Estado HTTP cuando el error vino de una respuesta; sólo sirve para el
  /// código de reporte.
  final int? statusCode;

  /// `reason` estable del cuerpo del error, si el servidor lo envía.
  final String? reason;

  const CloudSourceException(
    this.kind,
    this.message, {
    this.retryAfterSeconds,
    this.isVersionConflict = false,
    this.statusCode,
    this.reason,
  });

  /// Frase para el usuario. [message] (detalle del servidor o técnico) queda
  /// para el log: sólo se muestra tal cual donde el servidor escribe frases
  /// para personas (ver [cloudErrorMessage]).
  String get userMessage => cloudErrorMessage(
        kind,
        message,
        statusCode: statusCode,
        isVersionConflict: isVersionConflict,
        reason: reason,
      );

  /// Código corto para reportar (`E-CL-NET-500`). Nunca lleva detalle.
  String get code => cloudErrorCode(kind, statusCode: statusCode);

  /// [userMessage] más la línea "Código: ..." — lo que va a la pantalla.
  String get reportMessage => withReportCode(userMessage, code);

  @override
  String toString() => 'CloudSourceException($kind, $message)';
}

class CloudAccount {
  final String identity;
  final String? username;
  final int libraryVersion;
  final bool hasLibrary;
  final int friendCount;

  /// Lo que el servidor tiene guardado para "escuchando ahora". Es él quien
  /// descarta la presencia si está apagado, así que la preferencia local sólo
  /// vale si coincide con esto.
  final bool shareNowPlaying;

  const CloudAccount({
    required this.identity,
    required this.username,
    required this.libraryVersion,
    required this.hasLibrary,
    required this.friendCount,
    this.shareNowPlaying = false,
  });

  factory CloudAccount.fromJson(Map<String, dynamic> json) => CloudAccount(
        identity: (json['identity'] ?? '').toString(),
        username: json['username'] as String?,
        libraryVersion: (json['libraryVersion'] as num?)?.toInt() ?? 0,
        hasLibrary: json['hasLibrary'] == true,
        friendCount: (json['friendCount'] as num?)?.toInt() ?? 0,
        shareNowPlaying: json['shareNowPlaying'] == true,
      );
}

class CloudLibrary {
  final int version;
  final List<Map<String, dynamic>> songs;
  final List<Map<String, dynamic>> playlists;
  final List<Map<String, dynamic>> playlistSongs;

  /// Playlists online (`kind: 'online'`), APARTE de [playlists] a propósito:
  /// quien restaura archivos (`sync_status_screen.dart`, la pantalla de
  /// "En tus otros dispositivos") recorre [playlists] y las recrearía como
  /// playlists locales vacías. Sus pistas son referencias, no archivos.
  final List<Map<String, dynamic>> onlinePlaylists;

  /// Referencias a pistas de YouTube (`videoId`, título...). Nunca se ofrecen
  /// como archivo que descargar ni cuentan como canciones que faltan.
  final List<Map<String, dynamic>> remoteTracks;
  final List<Map<String, dynamic>> playlistRemoteTracks;

  const CloudLibrary({
    required this.version,
    required this.songs,
    required this.playlists,
    required this.playlistSongs,
    this.onlinePlaylists = const [],
    this.remoteTracks = const [],
    this.playlistRemoteTracks = const [],
  });

  /// `GET /library` es asimétrico con `PUT /library` a propósito de cómo
  /// está escrito el servidor, no por diseño: el push pasa por un modelo de
  /// Pydantic con alias camelCase (`songId`, `fileHash`...), pero la lectura
  /// (`library_store.py:get_library`) hace `SELECT` crudo y devuelve las
  /// columnas de Postgres tal cual (`song_id`, `file_hash`, snake_case) sin
  /// pasar por ningún modelo. Sin normalizar acá, cualquier código Dart que
  /// busque `song['fileHash']` — la convención que ya usa el resto de esta
  /// app — encuentra `null` siempre y trata todo como "sin hash", nunca como
  /// "falta" ni "está" (bug real: así es como `missingCloudSongs` reportaba
  /// falsamente "no falta nada", siempre, contra el servidor real).
  ///
  /// Un servidor anterior a las playlists online no manda `kind` ni las dos
  /// listas remotas: sin `kind` una playlist es local, y las listas ausentes
  /// quedan vacías.
  factory CloudLibrary.fromJson(Map<String, dynamic> json) {
    final allPlaylists = _camelCaseRows(json['playlists'], const {
      'playlist_id': 'playlistId',
      'sort_order': 'sortOrder',
      'original_url': 'originalUrl',
    });
    return CloudLibrary(
      version: (json['version'] as num?)?.toInt() ?? 0,
      songs: _camelCaseRows(json['songs'], const {
        'song_id': 'songId',
        'duration_seconds': 'durationSeconds',
        'file_hash': 'fileHash',
        'hash_kind': 'hashKind',
        'source_url': 'sourceUrl',
      }),
      playlists: [
        for (final row in allPlaylists)
          if (row['kind'] != 'online') row,
      ],
      onlinePlaylists: [
        for (final row in allPlaylists)
          if (row['kind'] == 'online') row,
      ],
      playlistSongs: _camelCaseRows(json['playlistSongs'], const {
        'playlist_id': 'playlistId',
        'song_id': 'songId',
        'order_index': 'orderIndex',
      }),
      remoteTracks: _camelCaseRows(json['remoteTracks'], const {
        'video_id': 'videoId',
        'duration_seconds': 'durationSeconds',
        'thumbnail_url': 'thumbnailUrl',
        'source_url': 'sourceUrl',
      }),
      playlistRemoteTracks: _camelCaseRows(json['playlistRemoteTracks'], const {
        'playlist_id': 'playlistId',
        'video_id': 'videoId',
        'order_index': 'orderIndex',
      }),
    );
  }

  static List<Map<String, dynamic>> _camelCaseRows(
    Object? rawList,
    Map<String, String> keyRenames,
  ) {
    final rows = List<Map<String, dynamic>>.from(rawList as List? ?? const []);
    return rows.map((row) {
      final renamed = <String, dynamic>{...row};
      for (final entry in keyRenames.entries) {
        if (renamed.containsKey(entry.key)) {
          renamed[entry.value] = renamed.remove(entry.key);
        }
      }
      return renamed;
    }).toList();
  }
}

/// `null` cuando el servidor respondió 304 (nada cambió desde la versión
/// pedida) — distinto de una biblioteca vacía, que sí trae listas vacías.
typedef CloudLibraryOrNotModified = CloudLibrary?;

/// Una página de `GET /history`. A diferencia de `GET /library`, estas filas
/// SÍ vienen en camelCase: la ruta las construye a mano fila a fila
/// (`library_store.py:get_history`) en vez de devolver el `SELECT` crudo, así
/// que no hace falta normalizar nada acá — ver el comentario de
/// [CloudLibrary.fromJson] para el caso contrario y por qué costó un bug.
class CloudHistoryPage {
  final List<Map<String, dynamic>> rows;
  final String? nextCursor;

  const CloudHistoryPage({required this.rows, this.nextCursor});

  factory CloudHistoryPage.fromJson(Map<String, dynamic> json) => CloudHistoryPage(
        rows: List<Map<String, dynamic>>.from(json['rows'] as List? ?? const []),
        nextCursor: json['nextCursor'] as String?,
      );
}

class HistoryPushResult {
  final int received;
  final int stored;
  final int skippedTooOld;

  const HistoryPushResult({required this.received, required this.stored, required this.skippedTooOld});

  factory HistoryPushResult.fromJson(Map<String, dynamic> json) => HistoryPushResult(
        received: (json['received'] as num?)?.toInt() ?? 0,
        stored: (json['stored'] as num?)?.toInt() ?? 0,
        skippedTooOld: (json['skippedTooOld'] as num?)?.toInt() ?? 0,
      );
}

class FriendEntry {
  final String username;
  final String? nowPlaying;

  const FriendEntry({required this.username, this.nowPlaying});

  factory FriendEntry.fromJson(Map<String, dynamic> json) => FriendEntry(
        username: (json['username'] ?? '').toString(),
        nowPlaying: json['nowPlaying'] as String?,
      );
}

class FriendsList {
  final List<FriendEntry> friends;
  final List<FriendEntry> incoming;
  final List<FriendEntry> outgoing;

  const FriendsList({required this.friends, required this.incoming, required this.outgoing});

  factory FriendsList.fromJson(Map<String, dynamic> json) => FriendsList(
        friends: (json['friends'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(FriendEntry.fromJson)
            .toList(),
        incoming: (json['incoming'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(FriendEntry.fromJson)
            .toList(),
        outgoing: (json['outgoing'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(FriendEntry.fromJson)
            .toList(),
      );
}

enum UserRelation { self, friend, pendingOutgoing, pendingIncoming, none }

UserRelation _relationFromJson(String raw) => switch (raw) {
      'self' => UserRelation.self,
      'friend' => UserRelation.friend,
      'pending_outgoing' => UserRelation.pendingOutgoing,
      'pending_incoming' => UserRelation.pendingIncoming,
      _ => UserRelation.none,
    };

class UserLookupResult {
  final String username;
  final UserRelation relation;

  const UserLookupResult({required this.username, required this.relation});

  factory UserLookupResult.fromJson(Map<String, dynamic> json) => UserLookupResult(
        username: (json['username'] ?? '').toString(),
        relation: _relationFromJson((json['relation'] ?? '').toString()),
      );
}

abstract class CloudSource {
  Future<CloudAccount> getAccount();

  Future<String> setUsername(String username);

  Future<UserLookupResult> lookupUser(String username);

  Future<String> sendFriendRequest(String username); // "pending" | "accepted"

  Future<void> acceptFriendRequest(String username);

  Future<void> rejectOrCancelFriendRequest(String username);

  Future<void> removeFriend(String username);

  Future<FriendsList> getFriends();

  Future<CloudLibraryOrNotModified> getLibrary({String? ifNoneMatchVersion});

  Future<int> pushLibrary({
    required int baseVersion,
    String? contentHash,
    required List<Map<String, dynamic>> songs,
    required List<Map<String, dynamic>> playlists,
    required List<Map<String, dynamic>> playlistSongs,
    List<Map<String, dynamic>> remoteTracks = const [],
    List<Map<String, dynamic>> playlistRemoteTracks = const [],
  });

  Future<HistoryPushResult> pushHistory(List<Map<String, dynamic>> rows, {int? utcOffsetMinutes});

  /// Escuchas por streaming de pistas guardadas (clave: `videoId`). Un
  /// servidor que no las conoce responde 404: [CloudSourceException] con
  /// `kind == notFound`, que el llamador trata como "no soportado".
  Future<HistoryPushResult> pushRemoteHistory(List<Map<String, dynamic>> rows, {int? utcOffsetMinutes});

  Future<CloudHistoryPage> getRemoteHistory({String? cursor, int limit = 500});

  /// Una página del historial propio guardado en la nube. [cursor] `null`
  /// empieza por el principio; [CloudHistoryPage.nextCursor] `null` significa
  /// que no hay más.
  Future<CloudHistoryPage> getHistory({String? cursor, int limit = 500});

  Future<Map<String, dynamic>> getStatsMe({required String period, int? utcOffsetMinutes});

  Future<Map<String, dynamic>> getStatsFriend(String username, {required String period});

  Future<void> putPresence({required String songId, required int expiresInSeconds});

  Future<void> clearPresence();

  Future<bool> setShareNowPlaying(bool enabled);

  Future<void> deleteAccountData();
}
