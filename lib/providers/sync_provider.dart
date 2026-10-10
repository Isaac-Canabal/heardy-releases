import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/audio_player_handler.dart';
import '../services/cloud_source.dart';
import '../l10n/app_localizations.dart';
import '../services/friendly_error.dart';
import '../services/database_helper.dart';
import '../services/library_diff.dart';
import 'package:heardy/services/app_log.dart';

/// Sincronización de cuenta (Etapa 16): índice de biblioteca + historial de
/// reproducción hacia el servidor. Misma forma que `DownloadProvider`: recibe
/// su servicio ([CloudSource]) y no sostiene otros providers — así queda
/// testeable con un doble y es un orquestador puro.
///
/// **Disparadores, todos señales reales, cero polling** (ver CLAUDE.md,
/// "Cloud sync"): arranque en frío, `AppLifecycleState.resumed` con
/// estrangulamiento, justo tras vincular/iniciar sesión, y el botón
/// "Sincronizar ahora".
///
/// **Simplificación deliberada frente al plan original:** en vez de un flag
/// `markLibraryDirty()` que cada punto de mutación de la biblioteca tendría
/// que llamar, este provider calcula un hash de contenido LOCAL antes de
/// cada intento de subida y sólo llama a la red si cambió desde la última
/// subida exitosa — el mismo atajo por `contentHash` que ya existe del lado
/// del servidor (ver `server/app/main.py:put_library`), aplicado también acá
/// para no depender de instrumentar cada sitio que cambia la biblioteca.
class SyncProvider with ChangeNotifier {
  final CloudSource _source;
  final DatabaseHelper _db;

  bool _isSyncing = false;
  DateTime? _lastSyncAt;
  String? _lastError;
  final List<({String step, Object error})> _stepFailures = [];
  CloudAccount? _account;
  int _libraryVersion = 0;
  String? _lastPushedContentHash;
  bool _hashLoadedFromPrefs = false;

  /// Cursor de la última página COMPLETA de `GET /history` ya bajada — nunca
  /// el de una página corta, que el servidor no la devuelve (ver
  /// `main.py:get_history`: "nextCursor ausente significa que no hay más
  /// páginas", así que una página corta no tiene de dónde sacar uno). Guardar
  /// sólo cursores de página llena es lo que mantiene el costo de cada pasada
  /// acotado a "lo nuevo desde la última vez" en vez de "todo el historial de
  /// la cuenta otra vez": en el peor caso se re-lee una página final que ya se
  /// había traído, y [insertRestoredPlays] la descarta por clave repetida.
  String? _historyCursor;
  bool _historyCursorLoadedFromPrefs = false;

  static const _prefsKeyLastPushedHash = 'sync_last_pushed_library_hash';
  static const _prefsKeyHistoryCursor = 'sync_history_cursor';
  static const _prefsKeyLastFullPullAt = 'sync_last_full_history_at';
  static const _prefsKeyLastFullPullHash = 'sync_last_full_history_hash';

  /// El cursor avanza por `played_at`, así que una fila que otro dispositivo
  /// sube tarde con un `played_at` viejo queda detrás para siempre, y una fila
  /// de una canción que acá todavía no existía se descarta sin que el cursor
  /// se entere. Una pasada completa (cursor en null) arregla ambas cosas.
  static const _fullPullMaxAge = Duration(hours: 24);
  int? _lastFullPullAtMs;
  String? _lastFullPullHash;

  int _historyRevision = 0;

  /// Sube cada vez que una bajada insertó filas: la UI de estadísticas lo
  /// observa para recalcular.
  int get historyRevision => _historyRevision;

  // --- "Escuchando ahora" (F8) ---
  final bool Function() _shareEnabled;
  StreamSubscription? _mediaItemSub;
  StreamSubscription<bool>? _playingSub;
  Timer? _minListenTimer;
  String? _currentSongId;
  Duration? _currentDuration;
  bool _currentlyPlaying = false;
  DateTime? _songStartedAt;
  DateTime? _lastPublishAt;
  String? _lastPublishedSongId;

  /// Una canción no se publica hasta llevar esto sonando — los saltos nunca
  /// llegan a la red.
  static const _minListenSeconds = 20;

  /// Mínimo entre dos peticiones de presencia — un cambio dentro de la
  /// ventana se agrupa (el `Timer` de [_minListenTimer] ya cumple ese papel
  /// al reprogramarse por canción), nunca se manda de más.
  static const _publishThrottle = Duration(seconds: 30);

  SyncProvider({
    required CloudSource source,
    DatabaseHelper? db,
    bool Function()? shareNowPlayingEnabled,
  })  : _source = source,
        _db = db ?? DatabaseHelper.instance,
        _shareEnabled = shareNowPlayingEnabled ?? (() => false);

  bool get isSyncing => _isSyncing;
  DateTime? get lastSyncAt => _lastSyncAt;
  String? get lastError => _lastError;

  /// [lastError] redactado en el idioma de la app (con el mismo código).
  String? localizedLastError(AppLocalizations l10n) {
    if (_lastError == null) return null;
    if (_stepFailures.isEmpty) return _lastError;
    final errors = _stepFailures.map((f) => localizedSyncStepError(l10n, f.step, f.error)).toList();
    final messages = errors.map((e) => e.message).toSet().join(' ');
    final codes = errors.map((e) => e.code).join(', ');
    return '$messages\n${l10n.errorCodeLine(codes)}';
  }

  CloudAccount? get account => _account;

  /// Actualiza el nombre de usuario cacheado al instante, sin esperar la
  /// próxima `syncNow()`. **El bug que esto corrige:** `ensureUsername`
  /// guarda el nombre contra el servidor directamente (no pasa por acá), así
  /// que hasta ahora la sección de Cuenta seguía mostrando "todavía no
  /// elegiste un nombre" — porque `_account` sólo se refrescaba en la
  /// siguiente pasada completa de `syncNow()`, y si esa pasada fallaba por
  /// cualquier otra razón (la biblioteca, el historial, la red), la UI daba
  /// la impresión de que el nombre nunca se había guardado. El nombre SÍ
  /// queda guardado en el servidor en cuanto `setUsername` responde 200 —
  /// esto sólo corrige que el cliente se entere sin depender de una
  /// sincronización completa y ajena.
  void noteUsernameSaved(String username) {
    final current = _account;
    _account = CloudAccount(
      identity: current?.identity ?? '',
      username: username,
      libraryVersion: current?.libraryVersion ?? _libraryVersion,
      hasLibrary: current?.hasLibrary ?? false,
      friendCount: current?.friendCount ?? 0,
    );
    notifyListeners();
  }

  /// Orden de una pasada: `GET /account` → subir historial pendiente en
  /// lotes de ≤500 → bajar el historial nuevo que otros dispositivos hayan
  /// subido desde el cursor guardado → si el contenido cambió, `PUT /library`.
  ///
  /// **La bajada automática de historial es lo que hace que las estadísticas
  /// coincidan entre dispositivos de la misma cuenta.** Antes `GET /history`
  /// sólo se llamaba a mano desde "Restaurar desde tu cuenta"
  /// (`sync_status_screen.dart`), así que un dispositivo nunca se enteraba de
  /// lo que otro había reproducido — cada uno calculaba sus estadísticas
  /// (`loadLocalStatistics`) contra su propio `play_history` nada más. Ese
  /// botón sigue existiendo como re-chequeo completo a mano; esto es el mismo
  /// mecanismo pero incremental y automático.
  ///
  /// **Historial y biblioteca son independientes y se intentan por separado.**
  /// Antes compartían un solo `try`, así que cualquier fallo subiendo el
  /// historial abortaba la pasada ANTES de llegar a la biblioteca. Como el
  /// historial se reintenta con las mismas filas en cada pasada, una fila
  /// rechazada de forma permanente (un 422, el cupo diario agotado) dejaba la
  /// biblioteca sin subir para siempre, en todos los dispositivos — el
  /// estado con el que se descubrió esto era una cuenta con
  /// `library_version == 0` meses después de empezar a usarla. Un paso que
  /// falla ahora se queda en [lastError] sin arrastrar al otro.
  ///
  /// `cuenta` sí corta la pasada: los dos pasos siguientes necesitan la
  /// identidad y la versión que devuelve.
  ///
  /// [fullHistory] (el botón manual) relee el historial desde el principio.
  Future<void> syncNow({bool fullHistory = false}) async {
    if (_isSyncing) return;
    _isSyncing = true;
    _lastError = null;
    _stepFailures.clear();
    notifyListeners();
    try {
      try {
        _account = await _source.getAccount();
        _libraryVersion = _account!.libraryVersion;
      } catch (e) {
        _lastError = _stepError('cuenta', e).report;
        return;
      }

      // Nombra el paso para que un fallo diga DÓNDE se rompió, no sólo qué
      // dijo el servidor: un mismo texto ("El servidor respondió 500") no
      // distingue cuál de las llamadas falló — que es exactamente lo que hizo
      // falta averiguar a mano la primera vez que esto no funcionó.
      final errors = [
        await _runStep('historial', _pushUnsyncedHistory),
        await _runStep('historial-nuevo', () => _pullNewHistory(forceFull: fullHistory)),
        await _runStep('biblioteca', _pushLibraryIfChanged),
        await _runStep('presencia', _reconcileShareNowPlaying),
      ].whereType<FriendlyError>().toList();

      if (errors.isEmpty) {
        _lastSyncAt = DateTime.now();
      } else {
        // Una sola frase por cada paso fallido y un único "Código:" con todos
        // los códigos, para que el usuario cite una línea y no tres.
        final messages = errors.map((e) => e.message).toSet().join(' ');
        final codes = errors.map((e) => e.code).join(', ');
        _lastError = withReportCode(messages, codes);
      }
    } finally {
      _isSyncing = false;
      notifyListeners();
    }
  }

  /// El interruptor de "escuchando ahora" vive en dos sitios: la preferencia
  /// local (SettingsProvider) y la fila de la cuenta en el servidor, que es
  /// quien descarta la presencia si está apagado. Hubo una versión en la que
  /// el interruptor sólo se guardaba en local y nadie veía nada: por eso
  /// además de empujarlo al cambiarlo ([setShareNowPlaying]) se reconcilia en
  /// cada sincronización, que arregla sola las instalaciones que ya lo tenían
  /// encendido.
  Future<void> _reconcileShareNowPlaying() async {
    final account = _account;
    if (account == null) return;
    final wanted = _shareEnabled();
    if (account.shareNowPlaying == wanted) return;
    await _source.setShareNowPlaying(wanted);
  }

  /// Empuja el interruptor al servidor en cuanto cambia. Devuelve lo que el
  /// servidor confirmó, o `null` si no se pudo hablar con él — la preferencia
  /// local se mantiene y la próxima sincronización lo vuelve a intentar.
  Future<bool?> setShareNowPlaying(bool enabled) async {
    try {
      final confirmed = await _source.setShareNowPlaying(enabled);
      if (!confirmed) _clearPresence();
      return confirmed;
    } catch (e) {
      appLog('SyncProvider: no se pudo guardar "escuchando ahora" en el servidor: $e');
      return null;
    }
  }

  /// Corre un paso y devuelve su error ya presentable, o `null` si fue bien.
  Future<FriendlyError?> _runStep(String name, Future<void> Function() body) async {
    try {
      await body();
      return null;
    } catch (e) {
      return _stepError(name, e);
    }
  }

  /// Cualquier cosa que no sea [CloudSourceException] (un fallo de SQLite, un
  /// error de parseo) también tiene que verse: antes escapaba de `syncNow`
  /// como un error de future sin capturar y la UI se quedaba igual que si
  /// nada hubiera pasado, que es el peor de los dos estados posibles.
  ///
  /// El texto crudo va al log; la UI recibe una frase sin etiquetas de paso
  /// (el paso viaja sólo en el código, ver [friendlySyncStepError]).
  FriendlyError _stepError(String step, Object error) {
    appLog('SyncProvider: falló el paso "$step" -> $error');
    _stepFailures.add((step: step, error: error));
    return friendlySyncStepError(step, error);
  }

  Future<void> _pushUnsyncedHistory() async {
    final offset = DateTime.now().timeZoneOffset.inMinutes;
    while (true) {
      final rows = await _db.getUnsyncedPlays(limit: 500);
      if (rows.isEmpty) return;

      final orphanIds = <int>[];
      final payloadIds = <int>[];
      final payload = <Map<String, dynamic>>[];
      for (final row in rows) {
        final id = row['id'] as int;
        if (row['existingSongId'] == null) {
          orphanIds.add(id);
          continue;
        }
        final playedAtUtc = (row['playedAtUtc'] as String?) ??
            DateTime.parse(row['playDate'] as String).toUtc().toIso8601String();
        payloadIds.add(id);
        payload.add({
          'songId': row['songId'],
          'playedAtLocal': row['playDate'],
          'playedAtUtc': playedAtUtc,
          'playSeconds': row['playDuration'] ?? 0,
        });
      }

      if (orphanIds.isNotEmpty) await _db.markPlaysSkipped(orphanIds);
      if (payload.isNotEmpty) {
        await _source.pushHistory(payload, utcOffsetMinutes: offset);
        // Si la llamada de arriba no lanzó, el servidor ya tomó una decisión
        // final sobre cada fila (aceptada o descartada por vieja) — marcar
        // todo el lote sincronizado, no sólo lo "stored", es correcto: no
        // hay nada que reintentar para una fila que el servidor ya vio.
        await _db.markPlaysSynced(payloadIds);
      }

      if (rows.length < 500) return;
    }
  }

  /// Baja las páginas de `GET /history` que aparecieron desde el cursor
  /// guardado — lo que otro dispositivo de la misma cuenta subió y este
  /// todavía no tiene. Mismo mecanismo que el botón manual de
  /// `sync_status_screen.dart`, pero incremental: arranca del cursor
  /// persistido en vez de desde el principio, así que el costo de cada pasada
  /// es "lo nuevo" y no "todo el historial de la cuenta" cada vez.
  ///
  /// Es completa (cursor en null) si se pide a mano, si la biblioteca local
  /// cambió desde la última pasada completa (canciones nuevas pueden destrabar
  /// filas descartadas antes) o si esa pasada tiene más de 24 h.
  Future<void> _pullNewHistory({bool forceFull = false}) async {
    final prefs = await SharedPreferences.getInstance();
    if (!_historyCursorLoadedFromPrefs) {
      _historyCursorLoadedFromPrefs = true;
      _historyCursor ??= prefs.getString(_prefsKeyHistoryCursor);
      _lastFullPullAtMs ??= prefs.getInt(_prefsKeyLastFullPullAt);
      _lastFullPullHash ??= prefs.getString(_prefsKeyLastFullPullHash);
    }

    final libraryHash = _hashOf(await _db.getLibraryIndexRows());
    final lastFullMs = _lastFullPullAtMs;
    final stale = lastFullMs == null ||
        DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(lastFullMs)) > _fullPullMaxAge;
    final full = forceFull || stale || libraryHash != _lastFullPullHash;

    if (full) {
      _historyCursor = null;
      await prefs.remove(_prefsKeyHistoryCursor);
    }

    final ctx = await _db.loadRestoreContext();
    var inserted = 0;
    var cursor = _historyCursor;
    try {
      while (true) {
        final page = await _source.getHistory(cursor: cursor);
        if (page.rows.isNotEmpty) {
          inserted += await _db.insertRestoredPlays(
            page.rows,
            knownSongs: ctx.knownSongs,
            existingKeys: ctx.existingKeys,
          );
        }
        if (page.nextCursor == null) break;
        cursor = page.nextCursor;
        _historyCursor = cursor;
        await prefs.setString(_prefsKeyHistoryCursor, cursor!);
      }
    } finally {
      if (inserted > 0) {
        _historyRevision++;
        notifyListeners();
      }
    }

    if (full) {
      _lastFullPullAtMs = DateTime.now().millisecondsSinceEpoch;
      _lastFullPullHash = libraryHash;
      await prefs.setInt(_prefsKeyLastFullPullAt, _lastFullPullAtMs!);
      await prefs.setString(_prefsKeyLastFullPullHash, libraryHash);
    }
  }

  /// Sube el índice sólo si el contenido LOCAL cambió desde la última subida
  /// de esta sesión, y nunca sin antes unirle lo que ya hay en la nube.
  ///
  /// El atajo por hash local va primero a propósito: si nada cambió acá, la
  /// nube ya tiene el resultado de la unión anterior y la pasada no cuesta ni
  /// una petición. Cuando sí cambió, la lectura de `/library` ocurre
  /// inmediatamente antes del `PUT` para que la unión sea contra el estado
  /// más fresco posible — si otro dispositivo se cuela entremedio, el
  /// servidor responde 409 y el conflicto se ve, que es lo que manda el
  /// diseño (CLAUDE.md, "Cloud sync").
  ///
  /// El hash que viaja al servidor es el del payload ya unido, no el del
  /// índice local: es lo que de verdad queda guardado, y es contra eso contra
  /// lo que el atajo por `contentHash` del servidor tiene que comparar.
  ///
  /// **`_lastPushedContentHash` se persiste en SharedPreferences.** En
  /// memoria no bastaba: se perdía en cada arranque en frío, así que el
  /// atajo "sólo sube si cambió" nunca aplicaba al abrir la app — cada
  /// apertura repetía el `PUT /library` completo aunque nada hubiera
  /// cambiado desde la sesión anterior, gastando el cupo diario del
  /// endpoint sin motivo.
  Future<void> _pushLibraryIfChanged() async {
    if (!_hashLoadedFromPrefs) {
      _hashLoadedFromPrefs = true;
      final prefs = await SharedPreferences.getInstance();
      _lastPushedContentHash ??= prefs.getString(_prefsKeyLastPushedHash);
    }

    final local = await _db.getLibraryIndexRows();
    final localHash = _hashOf(local);
    if (localHash == _lastPushedContentHash) return;

    final cloud = await _source.getLibrary();
    final merged = cloud == null
        ? local
        : unionCloudIntoLocalIndex(
            local: local,
            cloudSongs: cloud.songs,
            cloudPlaylists: cloud.playlists,
            cloudPlaylistSongs: cloud.playlistSongs,
          );

    final newVersion = await _source.pushLibrary(
      baseVersion: cloud?.version ?? _libraryVersion,
      contentHash: _hashOf(merged),
      songs: merged['songs']!,
      playlists: merged['playlists']!,
      playlistSongs: merged['playlistSongs']!,
    );
    _libraryVersion = newVersion;
    _lastPushedContentHash = localHash;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKeyLastPushedHash, localHash);
  }

  String _hashOf(Map<String, List<Map<String, dynamic>>> index) {
    // Orden estable antes de hashear: el mismo contenido en otro orden de
    // filas no debe verse como "cambió".
    final songs = [...index['songs']!]..sort((a, b) => '${a['songId']}'.compareTo('${b['songId']}'));
    final playlists = [...index['playlists']!]..sort((a, b) => '${a['playlistId']}'.compareTo('${b['playlistId']}'));
    final playlistSongs = [...index['playlistSongs']!]
      ..sort((a, b) => '${a['playlistId']}${a['songId']}'.compareTo('${b['playlistId']}${b['songId']}'));
    final bytes = utf8.encode(jsonEncode({'s': songs, 'p': playlists, 'ps': playlistSongs}));
    return md5.convert(bytes).toString();
  }

  /// Se suscribe a los streams que `AudioPlayerHandler` YA expone — nunca se
  /// toca ese archivo (~1000 líneas con historial de bugs sutiles y sin
  /// doble de prueba para `just_audio`; cero ediciones ahí = cero riesgo de
  /// romper la reproducción, ver CLAUDE.md). Idempotente: llamar más de una
  /// vez cancela las suscripciones previas primero.
  void attachPlayback(AudioPlayerHandler handler) {
    _mediaItemSub?.cancel();
    _playingSub?.cancel();
    _mediaItemSub = handler.mediaItem.distinct((a, b) => a?.id == b?.id).listen((item) {
      _currentSongId = item?.id;
      _currentDuration = item?.duration;
      _songStartedAt = DateTime.now();
      if (_currentlyPlaying && _currentSongId != null) _scheduleMinListenCheck();
    });
    _playingSub = handler.playbackState.map((s) => s.playing).distinct().listen((playing) {
      _currentlyPlaying = playing;
      if (playing) {
        _songStartedAt ??= DateTime.now();
        if (_currentSongId != null) _scheduleMinListenCheck();
      } else {
        _minListenTimer?.cancel();
        _clearPresence();
      }
    });
  }

  void _scheduleMinListenCheck() {
    _minListenTimer?.cancel();
    _minListenTimer = Timer(const Duration(seconds: _minListenSeconds), _maybePublishPresence);
  }

  void _maybePublishPresence() {
    if (!_shareEnabled() || !_currentlyPlaying) return;
    // Nunca un temporizador de latido: si nadie puede verla, publicar es
    // batería y datos tirados por nada.
    if ((_account?.friendCount ?? 0) <= 0) return;
    final songId = _currentSongId;
    final startedAt = _songStartedAt;
    if (songId == null || startedAt == null) return;

    final now = DateTime.now();
    if (songId == _lastPublishedSongId &&
        _lastPublishAt != null &&
        now.difference(_lastPublishAt!) < _publishThrottle) {
      return;
    }

    final elapsedSeconds = now.difference(startedAt).inSeconds;
    final duration = _currentDuration;
    // El TTL lo calcula el cliente: lo que le queda a la canción + 60s, así
    // la presencia caduca EXACTAMENTE cuando la canción habría terminado —
    // nunca un temporizador de "adiós" que Android podría no llegar a correr.
    final remaining = duration != null ? (duration.inSeconds - elapsedSeconds).clamp(0, 3600) : 180;
    final ttl = remaining + 60;

    _lastPublishAt = now;
    _lastPublishedSongId = songId;
    unawaited(_source.putPresence(songId: songId, expiresInSeconds: ttl).catchError((_) {}));
  }

  void _clearPresence() {
    if (_lastPublishedSongId == null) return;
    _lastPublishedSongId = null;
    unawaited(_source.clearPresence().catchError((_) {}));
  }

  @override
  void dispose() {
    _mediaItemSub?.cancel();
    _playingSub?.cancel();
    _minListenTimer?.cancel();
    super.dispose();
  }

  /// La válvula de escape de privacidad: borra biblioteca/historial/
  /// amistades de la cuenta en el servidor, y resetea las marcas locales de
  /// `syncedAt` para que un revínculo posterior resuba todo desde cero.
  Future<void> deleteCloudData() async {
    await _source.deleteAccountData();
    await _db.resetHistorySyncMarkers();
    _lastPushedContentHash = null;
    _hashLoadedFromPrefs = true;
    _historyCursor = null;
    _historyCursorLoadedFromPrefs = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKeyLastPushedHash);
    await prefs.remove(_prefsKeyHistoryCursor);
    await prefs.remove(_prefsKeyLastFullPullAt);
    await prefs.remove(_prefsKeyLastFullPullHash);
    _lastFullPullAtMs = null;
    _lastFullPullHash = null;
    _libraryVersion = 0;
    _lastSyncAt = null;
    notifyListeners();
  }
}
