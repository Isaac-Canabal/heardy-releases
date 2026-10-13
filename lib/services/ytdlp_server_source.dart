import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/explore.dart';
import 'download_source.dart';
import 'friendly_error.dart';
import 'server_pool.dart';
import 'app_log.dart';

/// Cliente HTTP del microservidor yt-dlp propio (`server/` en este repo).
///
/// Usa el paquete `http`, que ya era dependencia por `lyrics_service.dart`.
/// Toda llamada lleva timeout explícito: sin él una petición a un servidor
/// que acepta la conexión pero no responde cuelga para siempre y sin registro
/// (el mismo error que la capa de descargas anterior arrastró durante meses).
class YtdlpServerSource implements DownloadSource {
  /// Búsqueda: la UI está esperando, pero fallar antes de tiempo es peor que
  /// esperar — ver [_resolveTimeout].
  static const _searchTimeout = Duration(seconds: 60);

  /// Resolver un vídeo. **Eran 30 s y era demasiado poco**, con un fallo que
  /// parecía otra cosa: el servidor oficial corre en un plan gratuito con
  /// ~0,1 vCPU y además se duerme tras un rato inactivo. `/health` es trivial
  /// y contesta en menos de medio segundo (así que la app y el usuario lo ven
  /// perfectamente "activo"), pero `/resolve` ejecuta yt-dlp resolviendo el
  /// desafío de firma de YouTube en JavaScript, que es puro CPU: con esa
  /// cuota pasa de 30 s con normalidad, y arrancar en frío se suma encima.
  /// El resultado era un timeout presentado como "no se pudo contactar con el
  /// servidor" mientras el servidor estaba vivo y trabajando — el peor de los
  /// mensajes posibles, porque manda a investigar la red.
  ///
  /// Medido: el mismo `/resolve` contra un servidor local sin estrangular
  /// tarda 2,6-3,9 s. Todo lo que hay por encima de eso es la cuota de CPU
  /// del alojamiento, no el trabajo en sí.
  static const _resolveTimeout = Duration(seconds: 120);

  /// Explorar: el servidor corta a los 20 s; el margen cubre el arranque en frío.
  static const _exploreTimeout = Duration(seconds: 45);

  /// Expandir una playlist larga da bastante más trabajo al servidor.
  static const _playlistTimeout = Duration(seconds: 120);

  /// El servidor baja el vídeo antes de responder, así que la primera cabecera
  /// puede tardar. No cubre la transferencia entera, solo el arranque.
  static const _audioHeaderTimeout = Duration(minutes: 5);

  /// Silencio máximo entre trozos ya empezada la transferencia. Corta una
  /// conexión colgada sin abortar una descarga lenta pero viva.
  static const _audioIdleTimeout = Duration(seconds: 90);

  final String Function() _baseUrlProvider;
  final Future<String?> Function() _authTokenProvider;
  final String Function()? _apiKeyProvider;
  final http.Client Function() _clientFactory;
  final ServerPool? _pool;

  /// [authToken] reemplaza la antigua clave de API compilada (Fase 2 del
  /// plan de seguridad, A1): es el token de ID de Firebase de quien inició
  /// sesión, mandado como `Authorization: Bearer`. `null`/vacío sin sesión —
  /// en ese caso las llamadas llegan sin autenticación y el servidor las
  /// rechaza con 401, que [DownloadSourceErrorKind.unauthorized] ya sabe
  /// interpretar.
  ///
  /// [apiKey] es el mecanismo viejo (`X-Api-Key`), opcional y sin usar por la
  /// app en sí (la clave compilada se quitó con este mismo cambio): sigue
  /// existiendo acá sólo porque el servidor mismo sigue aceptándolo para un
  /// servidor personal o de desarrollo (ver `server/app/auth.py`,
  /// `resolve_identity`), y es lo que exercita
  /// `test/download_live_integration_test.dart` contra un servidor local
  /// levantado con `HEARDY_API_KEY`. Cuando [authToken] resuelve un valor no
  /// vacío tiene prioridad — mismo orden que el servidor usa para decidir
  /// cuál de los dos mecanismos se está usando.
  YtdlpServerSource({
    required String Function() baseUrl,
    required Future<String?> Function() authToken,
    String Function()? apiKey,
    http.Client Function()? clientFactory,
    ServerPool? pool,
  })  : _baseUrlProvider = baseUrl,
        _authTokenProvider = authToken,
        _apiKeyProvider = apiKey,
        _pool = pool,
        _clientFactory = clientFactory ?? (() => http.Client());

  bool get isConfigured => _normalizedBase() != null;

  /// Normaliza lo que el usuario escribió en Ajustes: acepta `192.168.1.5:8080`
  /// tanto como `http://192.168.1.5:8080/`, porque nadie escribe el esquema.
  String? _normalizedBase([String? candidate]) {
    var raw = (candidate ?? _pool?.current() ?? _baseUrlProvider()).trim();
    if (raw.isEmpty) return null;
    if (!raw.startsWith('http://') && !raw.startsWith('https://')) {
      raw = 'http://$raw';
    }
    while (raw.endsWith('/')) {
      raw = raw.substring(0, raw.length - 1);
    }
    final parsed = Uri.tryParse(raw);
    if (parsed == null || parsed.host.isEmpty) return null;
    return raw;
  }

  Uri _uri(String path, [Map<String, String>? query, String? baseOverride]) {
    final base = _normalizedBase(baseOverride);
    if (base == null) {
      throw const DownloadSourceException(
        DownloadSourceErrorKind.notConfigured,
        'No hay servidor de descargas configurado',
      );
    }
    return Uri.parse('$base$path').replace(queryParameters: query);
  }

  Future<Map<String, String>> _headers({bool json = false}) async {
    final token = await _authTokenProvider();
    final apiKey = _apiKeyProvider?.call().trim();
    return {
      if (token != null && token.isNotEmpty)
        'Authorization': 'Bearer $token'
      else if (apiKey != null && apiKey.isNotEmpty)
        'X-Api-Key': apiKey,
      if (json) 'Content-Type': 'application/json',
    };
  }

  /// Corre [op] contra el primer servidor del [ServerPool] con capacidad; si
  /// el alojamiento lo suspendió por ancho de banda, lo da de baja y repite
  /// contra el siguiente. Sin pool (desarrollo, tests) corre [op] una vez.
  Future<T> _withFailover<T>(Future<T> Function(String? base) op) async {
    final pool = _pool;
    if (pool == null) return op(null);
    while (true) {
      final base = pool.current();
      if (base == null) {
        throw DownloadSourceException(
          DownloadSourceErrorKind.serverCapacityExhausted,
          serverCapacityMessage(
            pool.allExhaustedUntil.value ?? ServerPool.nextMonthStartUtc(DateTime.now()),
          ),
        );
      }
      try {
        final result = await op(base);
        pool.markHealthy(base);
        return result;
      } on DownloadSourceException catch (e) {
        if (e.kind == DownloadSourceErrorKind.serverCapacityExhausted) {
          pool.markExhausted(base);
          continue;
        }
        if (e.kind != DownloadSourceErrorKind.network) pool.markHealthy(base);
        rethrow;
      }
    }
  }

  /// Traduce un fallo de transporte al tipo que la cola sabe interpretar.
  ///
  /// La última rama es un cajón de sastre: cualquier excepción que no sea
  /// ninguna de las anteriores acaba como `network`. El texto crudo va al log
  /// y a `message` (para `lastError`), pero `userMessage` nunca lo muestra:
  /// así un timeout, un fallo de TLS y un error de parseo siguen
  /// distinguiéndose al diagnosticar sin filtrarse a la pantalla.
  Never _rethrowAsSourceError(Object error) {
    if (error is DownloadSourceException) throw error;
    appLog('YtdlpServerSource: fallo de transporte (${error.runtimeType}) -> $error');
    if (error is TimeoutException) {
      throw const DownloadSourceException(
        DownloadSourceErrorKind.network,
        // Render duerme el servicio en el plan gratuito: el primer intento
        // tras un rato de inactividad puede tardar más que el timeout, y el
        // segundo va rápido. Decirlo evita leer "está caído" cuando está
        // despertando.
        'tardó demasiado en responder (si estuvo inactivo, puede estar '
            'arrancando — prueba de nuevo en un minuto)',
      );
    }
    throw DownloadSourceException(
      DownloadSourceErrorKind.network,
      '${error.runtimeType}: $error',
    );
  }

  /// Mapea el código HTTP al tipo de error. El 415 del servidor es
  /// deliberadamente distinto del 502: significa "este vídeo no tiene pista
  /// AAC", que es definitivo, mientras que el 502 sí merece reintento.
  ///
  /// [retryAfterHeader] sólo se usa para el 429: es la cabecera `Retry-After`
  /// que el servidor calcula a partir de su propio limitador (nunca
  /// inventada acá, ver `DownloadSourceException.retryAfterSeconds`).
  void _checkStatus(int statusCode, String body, {String? retryAfterHeader, Map<String, String>? headers}) {
    if (statusCode >= 200 && statusCode < 300) return;
    if (looksLikeCapacityExhausted(statusCode, headers ?? const {}, body)) {
      throw DownloadSourceException(
        DownloadSourceErrorKind.serverCapacityExhausted,
        serverCapacityMessage(ServerPool.nextMonthStartUtc(DateTime.now())),
      );
    }
    final detail = _detailFrom(body);
    final reason = reasonFromBody(body);
    appLog('YtdlpServerSource: respuesta $statusCode -> $detail');
    switch (statusCode) {
      case 401:
      case 403:
        throw DownloadSourceException(DownloadSourceErrorKind.unauthorized, detail, statusCode: statusCode, reason: reason);
      case 451:
        throw DownloadSourceException(DownloadSourceErrorKind.blockedLegal, detail, statusCode: statusCode, reason: reason);
      case 415:
        throw DownloadSourceException(DownloadSourceErrorKind.unsupportedMedia, detail, statusCode: statusCode);
      case 404:
        // El servidor reserva el 404 para lo definitivo: vídeo borrado,
        // privado, sólo para miembros, restringido por edad, o URL inválida.
        // Lo pasajero (su IP bloqueada, un corte de red) sale como 502.
        throw DownloadSourceException(DownloadSourceErrorKind.notFound, detail, statusCode: statusCode);
      case 400:
      case 413:
      case 422:
        // NO notFound: un 400/422 lo decide la forma del cuerpo, no el
        // estado del vídeo. Colapsarlos hacía que un fallo de contrato entre
        // cliente y servidor se presentara como "ese vídeo ya no está
        // disponible" sobre un vídeo intacto.
        if (reason == 'song_too_long') {
          throw DownloadSourceException(DownloadSourceErrorKind.songTooLong, detail, statusCode: statusCode);
        }
        throw DownloadSourceException(DownloadSourceErrorKind.badRequest, detail, statusCode: statusCode);
      case 429:
        // El propio servidor se autolimitó (no YouTube): distinto de un 502
        // porque acá sí sabemos, con certeza, cuánto hay que esperar.
        //
        // Dos motivos posibles, distinguidos por `reason` en el cuerpo
        // (Fase 3 del plan de seguridad): el límite de PETICIONES de
        // `rate_limit.py` (sin `reason`, protección anti-abuso) o el cupo
        // diario de CANCIONES por cuenta (`reason: "daily_song_quota"`, un
        // límite de producto — "llegaste a tus 150 de hoy" merece su propio
        // mensaje, no el genérico de arriba).
        throw DownloadSourceException(
          (reason == 'daily_song_quota' || reason == 'monthly_song_quota')
              ? DownloadSourceErrorKind.dailyQuotaExceeded
              : DownloadSourceErrorKind.quotaExceeded,
          detail,
          retryAfterSeconds: int.tryParse((retryAfterHeader ?? '').trim()),
          statusCode: statusCode,
          reason: reason,
        );
      case 503:
        // El servidor distingue el muro anti-bot de YouTube de un 502
        // genérico (ver `AntiBotBlockError` en el servidor) precisamente para
        // que la cola le dé un trato distinto: minutos de espera real, no el
        // backoff corto de un 502 cualquiera.
        if (reason == 'auth_unavailable' ||
            reason == 'not_configured' ||
            (reason != 'antibot' && (retryAfterHeader ?? '').trim().isNotEmpty)) {
          // Con `Retry-After` no es el muro anti-bot sino un servicio interno
          // (verificación de sesión) que no responde un momento.
          throw DownloadSourceException(
            DownloadSourceErrorKind.serviceUnavailable,
            detail,
            retryAfterSeconds: int.tryParse((retryAfterHeader ?? '').trim()),
            statusCode: statusCode,
            reason: reason,
          );
        }
        throw DownloadSourceException(DownloadSourceErrorKind.antiBotBlocked, detail, statusCode: statusCode, reason: reason);
      default:
        throw DownloadSourceException(
          DownloadSourceErrorKind.extraction,
          'El servidor respondió $statusCode: $detail',
          statusCode: statusCode,
        );
    }
  }

  String _detailFrom(String body) {
    // Sólo para log y `lastError`: la UI nunca lo muestra (ver `userMessage`).
    if (body.isEmpty) return 'sin detalle';
    if (looksLikeHtml(body)) return 'respuesta inesperada del servidor';
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['detail'] != null) {
        return decoded['detail'].toString();
      }
    } catch (_) {
      // Cuerpo no-JSON (p. ej. una página de error de un proxy intermedio).
    }
    return body.length > 300 ? '${body.substring(0, 300)}…' : body;
  }

  Future<Map<String, dynamic>> _postJson(String path, Map<String, dynamic> body, Duration timeout) =>
      _withFailover((base) => _postJsonOnce(path, body, timeout, base));

  Future<Map<String, dynamic>> _postJsonOnce(
    String path,
    Map<String, dynamic> body,
    Duration timeout,
    String? base,
  ) async {
    final client = _clientFactory();
    try {
      final response = await client
          .post(_uri(path, null, base), headers: await _headers(json: true), body: jsonEncode(body))
          .timeout(timeout);
      _checkStatus(
        response.statusCode,
        response.body,
        retryAfterHeader: response.headers['retry-after'],
        headers: response.headers,
      );
      return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    } catch (e) {
      _rethrowAsSourceError(e);
    } finally {
      client.close();
    }
  }

  @override
  Future<RemoteTrack> resolve(String url) async {
    final json = await _postJson('/resolve', {'url': url}, _resolveTimeout);
    return RemoteTrack.fromJson(json);
  }

  @override
  Future<RemotePlaylist> resolvePlaylist(String url) async {
    final json = await _postJson('/playlist', {'url': url}, _playlistTimeout);
    return RemotePlaylist.fromJson(json);
  }

  @override
  Future<List<RemoteTrack>> search(String query, {int limit = 20}) =>
      _withFailover((base) => _searchOnce(query, limit, base));

  Future<List<RemoteTrack>> _searchOnce(String query, int limit, String? base) async {
    final client = _clientFactory();
    try {
      final response = await client
          .get(_uri('/search', {'q': query, 'limit': '$limit'}, base), headers: await _headers())
          .timeout(_searchTimeout);
      _checkStatus(
        response.statusCode,
        response.body,
        retryAfterHeader: response.headers['retry-after'],
        headers: response.headers,
      );
      final json = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      return (json['results'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(RemoteTrack.fromJson)
          .where((t) => t.id.isNotEmpty)
          .toList();
    } catch (e) {
      _rethrowAsSourceError(e);
    } finally {
      client.close();
    }
  }

  Future<Object?> _getJson(String path, Map<String, String>? query, Duration timeout) =>
      _withFailover((base) => _getJsonOnce(path, query, timeout, base));

  Future<Object?> _getJsonOnce(String path, Map<String, String>? query, Duration timeout, String? base) async {
    final client = _clientFactory();
    try {
      final response = await client.get(_uri(path, query, base), headers: await _headers()).timeout(timeout);
      _checkStatus(
        response.statusCode,
        response.body,
        retryAfterHeader: response.headers['retry-after'],
        headers: response.headers,
      );
      return jsonDecode(utf8.decode(response.bodyBytes));
    } catch (e) {
      _rethrowAsSourceError(e);
    } finally {
      client.close();
    }
  }

  static Map<String, String>? _countryQuery(String? country, [Map<String, String> extra = const {}]) {
    final q = {if (country != null && country.isNotEmpty) 'country': country, ...extra};
    return q.isEmpty ? null : q;
  }

  static Map<String, String> _freshQuery(bool fresh) => fresh ? const {'fresh': '1'} : const {};

  @override
  Future<List<ExploreShelf>> exploreHome({String? country, bool fresh = false}) async =>
      parseExploreHome(await _getJson('/explore/home', _countryQuery(country, _freshQuery(fresh)), _exploreTimeout));

  @override
  Future<List<ExplorePlaylist>> exploreCharts({String? country, bool fresh = false}) async =>
      parseExplorePlaylists(await _getJson('/explore/charts', _countryQuery(country, _freshQuery(fresh)), _exploreTimeout));

  @override
  Future<List<ExploreAlbum>> exploreNewReleases({String? country, bool fresh = false}) async =>
      parseExploreAlbums(await _getJson('/explore/new-releases', _countryQuery(country, _freshQuery(fresh)), _exploreTimeout));

  @override
  Future<List<ExploreMoodSection>> exploreMoods({String? country, bool fresh = false}) async =>
      parseExploreMoods(await _getJson('/explore/moods', _countryQuery(country, _freshQuery(fresh)), _exploreTimeout));

  @override
  Future<List<ExplorePlaylist>> exploreMood(String params, {String? country}) async => parseExplorePlaylists(
        await _getJson('/explore/mood', _countryQuery(country, {'params': params}), _exploreTimeout),
      );

  @override
  Future<ExploreCollection> explorePlaylist(String playlistId) async => parseExploreCollection(
        await _getJson('/explore/playlist/${Uri.encodeComponent(playlistId)}', null, _exploreTimeout),
      );

  @override
  Future<ExploreCollection> exploreAlbum(String browseId) async => parseExploreCollection(
        await _getJson('/explore/album/${Uri.encodeComponent(browseId)}', null, _exploreTimeout),
      );

  @override
  Future<List<RemoteTrack>> exploreRadio(String seedVideoId) async =>
      parseExploreRadio(await _getJson('/explore/radio', {'seed': seedVideoId}, _exploreTimeout));

  @override
  Future<ExploreArtist> exploreArtist(String channelId) async => parseExploreArtist(
        await _getJson('/explore/artist/${Uri.encodeComponent(channelId)}', null, _exploreTimeout),
      );

  @override
  Future<ExploreSearchResults> exploreSearch(String query, ExploreSearchKind kind, {String? country}) async =>
      parseExploreSearch(
        kind,
        await _getJson('/explore/search', _countryQuery(country, {'q': query, 'type': kind.name}), _exploreTimeout),
      );

  @override
  Future<List<ExploreArtistHit>> exploreArtistSearch(String query) async =>
      parseExploreArtistSearch(await _getJson('/explore/artist-search', {'q': query}, _exploreTimeout));

  @override
  Future<void> fetchAudio(
    String trackId,
    String destPath, {
    ProgressCallback? onProgress,
    CancellationCheck? isCancelled,
  }) =>
      _withFailover(
        (base) => _fetchAudioOnce(trackId, destPath, base, onProgress: onProgress, isCancelled: isCancelled),
      );

  Future<void> _fetchAudioOnce(
    String trackId,
    String destPath,
    String? base, {
    ProgressCallback? onProgress,
    CancellationCheck? isCancelled,
  }) async {
    final client = _clientFactory();
    final destFile = File(destPath);
    IOSink? sink;
    try {
      final request = http.Request('GET', _uri('/audio/$trackId', null, base))
        ..headers.addAll(await _headers());
      final response = await client.send(request).timeout(_audioHeaderTimeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = await response.stream.bytesToString();
        _checkStatus(
          response.statusCode,
          body,
          retryAfterHeader: response.headers['retry-after'],
          headers: response.headers,
        );
      }

      final total = response.contentLength;
      var received = 0;

      await destFile.parent.create(recursive: true);
      sink = destFile.openWrite();

      // El timeout es por-trozo, no global: una descarga lenta pero viva no
      // debe morir, una conexión colgada sí.
      await for (final chunk in response.stream.timeout(_audioIdleTimeout)) {
        if (isCancelled?.call() ?? false) {
          throw const DownloadSourceException(
            DownloadSourceErrorKind.cancelled,
            'Descarga cancelada',
          );
        }
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }

      await sink.flush();
      await sink.close();
      sink = null;

      if (received == 0) {
        throw const DownloadSourceException(
          DownloadSourceErrorKind.extraction,
          'El servidor devolvió una respuesta vacía',
        );
      }
      // Una transferencia cortada limpiamente a mitad llega aquí sin error de
      // socket; solo Content-Length delata que falta contenido.
      if (total != null && received < total) {
        throw DownloadSourceException(
          DownloadSourceErrorKind.network,
          'Transferencia incompleta: $received de $total bytes',
        );
      }
    } catch (e) {
      // El archivo parcial nunca debe sobrevivir: DownloadService lo pegaría
      // en la biblioteca del usuario como si fuera una canción.
      try {
        await sink?.close();
      } catch (_) {}
      try {
        if (await destFile.exists()) await destFile.delete();
      } catch (_) {}
      _rethrowAsSourceError(e);
    } finally {
      client.close();
    }
  }

  @override
  Future<DownloadSourceStatus> probe() async {
    if (_normalizedBase() == null) {
      return const DownloadSourceStatus(
        reachable: false,
        authenticated: false,
        version: null,
        potProviderReachable: false,
        detail: 'No hay dirección de servidor configurada',
        problem: DownloadProbeProblem.noServer,
      );
    }

    final client = _clientFactory();
    try {
      // /health no pide autenticación a propósito, para poder distinguir
      // "servidor apagado" de "clave incorrecta".
      //
      // 45 s y no 10: un servicio dormido en un plan gratuito tarda decenas
      // de segundos en levantarse, y con 10 s el diagnóstico contestaba
      // "apagado" justo cuando estaba arrancando — el diagnóstico existe para
      // resolver esa duda, no para añadirle otra.
      final health = await client.get(_uri('/health')).timeout(const Duration(seconds: 45));
      if (health.statusCode != 200) {
        return DownloadSourceStatus(
          reachable: false,
          authenticated: false,
          version: null,
          potProviderReachable: false,
          detail: looksLikeCapacityExhausted(health.statusCode, health.headers, health.body)
              ? serverCapacityMessage(ServerPool.nextMonthStartUtc(DateTime.now()))
              : 'El servidor no está disponible ahora mismo. '
                  'Código: ${downloadErrorCode(DownloadSourceErrorKind.extraction, statusCode: health.statusCode)}',
          problem: looksLikeCapacityExhausted(health.statusCode, health.headers, health.body)
              ? DownloadProbeProblem.capacity
              : DownloadProbeProblem.serviceDown,
          statusCode: health.statusCode,
        );
      }

      final json = jsonDecode(utf8.decode(health.bodyBytes)) as Map<String, dynamic>;
      final pot = json['potProvider'] as Map<String, dynamic>? ?? const {};
      final authRequired = json['authRequired'] == true;

      var authenticated = !authRequired;
      var detail = 'Conectado';
      DownloadProbeProblem? problem;
      if (authRequired) {
        // Una llamada autenticada barata es la única forma de saber si la
        // clave sirve, porque /health no la pide.
        final probe = await client
            .get(_uri('/search', {'q': 'heardy', 'limit': '1'}), headers: await _headers())
            .timeout(const Duration(seconds: 20));
        authenticated = probe.statusCode != 401 && probe.statusCode != 403;
        if (!authenticated) {
          detail = 'La clave de acceso no es válida. Inicia sesión de nuevo.';
          problem = DownloadProbeProblem.keyInvalid;
        }
      }

      if (authenticated && pot['reachable'] != true) {
        detail = 'Conectado, pero el proveedor de PO tokens no responde: '
            'la mayoría de descargas fallarán';
        problem = DownloadProbeProblem.potDown;
      }

      return DownloadSourceStatus(
        reachable: true,
        authenticated: authenticated,
        version: json['ytdlpVersion']?.toString(),
        potProviderReachable: pot['reachable'] == true,
        detail: detail,
        problem: problem,
      );
    } catch (e) {
      return DownloadSourceStatus(
        reachable: false,
        authenticated: false,
        version: null,
        potProviderReachable: false,
        detail: e is TimeoutException
            ? 'El servidor no respondió a tiempo'
            : 'No se pudo contactar con el servidor',
        problem: e is TimeoutException ? DownloadProbeProblem.timeout : DownloadProbeProblem.unreachable,
      );
    } finally {
      client.close();
    }
  }

  @override
  Future<UsageStatus> usage() async {
    if (_normalizedBase() == null) return UsageStatus.disabled;
    final client = _clientFactory();
    try {
      final response = await client
          .get(_uri('/usage'), headers: await _headers())
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return UsageStatus.disabled;
      final json = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      return UsageStatus.fromJson(json);
    } catch (_) {
      // No lanza a propósito (ver el doc de DownloadSource.usage): un fallo
      // acá se ve exactamente igual que "no hay cupo activo", y ninguno de
      // los dos amerita bloquear la pantalla de Añadir por esto.
      return UsageStatus.disabled;
    } finally {
      client.close();
    }
  }
}
