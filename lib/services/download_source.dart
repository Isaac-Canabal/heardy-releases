/// Abstracción sobre "de dónde salen los bytes de audio".
///
/// Existe para que cambiar de proveedor (hoy el microservidor yt-dlp propio,
/// mañana una API comercial si hiciera falta) sea una implementación nueva y
/// no un rediseño. Ver CLAUDE.md DD1.
///
/// **No la hagas crecer sin un segundo proveedor real que lo justifique.**
library;

import '../models/explore.dart';
import 'friendly_error.dart';

/// Una pista remota ya resuelta, lista para descargar.
class RemoteTrack {
  /// Id en la fuente (para YouTube, el id de vídeo de 11 caracteres).
  final String id;
  final String title;
  final String artist;
  final String? album;
  final int durationSeconds;
  final String thumbnailUrl;

  /// URL canónica de origen. Se persiste en `songs.sourceUrl` para poder
  /// detectar "esto ya está descargado" sin gastar red.
  final String sourceUrl;

  const RemoteTrack({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.durationSeconds,
    required this.thumbnailUrl,
    required this.sourceUrl,
  });

  factory RemoteTrack.fromJson(Map<String, dynamic> json) {
    return RemoteTrack(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      artist: (json['artist'] ?? '').toString(),
      album: (json['album'] as String?)?.trim().isEmpty ?? true ? null : json['album'] as String,
      durationSeconds: (json['durationSeconds'] as num?)?.toInt() ?? 0,
      thumbnailUrl: (json['thumbnailUrl'] ?? '').toString(),
      sourceUrl: (json['sourceUrl'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artist': artist,
        'album': album,
        'durationSeconds': durationSeconds,
        'thumbnailUrl': thumbnailUrl,
        'sourceUrl': sourceUrl,
      };
}

/// URL directa de audio de un vídeo, para escucharlo sin descargarlo.
///
/// Efímera: la URL va firmada para la IP que la pidió y caduca ([expiresAt]).
/// Nunca se persiste ni se registra en logs.
class StreamInfo {
  final String videoId;
  final String url;
  final String mimeType;

  /// Epoch en segundos, o null si la URL no declara caducidad.
  final int? expiresAt;
  final int? contentLength;
  final int durationSeconds;

  /// Cabeceras que el reproductor debe mandar al pedir [url].
  final Map<String, String> httpHeaders;
  final bool audioOnly;
  final double? bitrateKbps;

  const StreamInfo({
    required this.videoId,
    required this.url,
    required this.mimeType,
    required this.expiresAt,
    required this.contentLength,
    required this.durationSeconds,
    required this.httpHeaders,
    required this.audioOnly,
    required this.bitrateKbps,
  });

  @override
  String toString() => 'StreamInfo($videoId, $mimeType, audioOnly=$audioOnly)';
}

/// Una playlist remota ya expandida.
class RemotePlaylist {
  final String id;
  final String name;
  final String sourceUrl;
  final List<RemoteTrack> entries;

  const RemotePlaylist({
    required this.id,
    required this.name,
    required this.sourceUrl,
    required this.entries,
  });

  factory RemotePlaylist.fromJson(Map<String, dynamic> json) {
    final rawEntries = (json['entries'] as List<dynamic>? ?? const []);
    return RemotePlaylist(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? 'Playlist').toString(),
      sourceUrl: (json['sourceUrl'] ?? '').toString(),
      entries: rawEntries
          .whereType<Map<String, dynamic>>()
          .map(RemoteTrack.fromJson)
          .where((t) => t.id.isNotEmpty)
          .toList(),
    );
  }
}

/// Por qué falló una operación. La UI y la cola de descargas necesitan
/// distinguirlos: solo [network] y [server] merecen reintento, y solo
/// [notConfigured] y [unauthorized] se arreglan tocando ajustes.
enum DownloadSourceErrorKind {
  /// No hay URL de servidor configurada todavía.
  notConfigured,

  /// El servidor no responde: apagado, fuera de la VPN, sin red.
  network,

  /// X-Api-Key ausente o incorrecta.
  unauthorized,

  /// 400/422 — el SERVIDOR rechazó la petición por su forma, no por el
  /// vídeo. Es un fallo de contrato entre dos piezas nuestras, así que
  /// reintentar el mismo cuerpo no puede funcionar; pero tampoco es culpa del
  /// vídeo. Antes caía en [notFound] y la app decía "ese vídeo ya no está
  /// disponible" sobre uno perfectamente sano, mandando a buscar el problema
  /// al sitio equivocado.
  badRequest,

  /// El servidor respondió pero no pudo extraer, y el fallo **puede ser
  /// pasajero**: su IP bloqueada por YouTube, un corte de red por su lado.
  /// Reintentar tiene sentido.
  extraction,

  /// El vídeo ya no existe para nadie: borrado, privado, sólo para miembros,
  /// con restricción de edad, o la URL no era válida. **Definitivo.**
  /// Reintentar no puede funcionar nunca, así que la cola lo descarta en vez
  /// de gastar en él su presupuesto de reintentos.
  notFound,

  /// El vídeo no tiene ninguna pista de audio AAC/M4A. Definitivo: no tiene
  /// sentido reintentarlo.
  unsupportedMedia,

  /// El propio servidor rechazó la petición por límite de peticiones (HTTP
  /// 429) — no es YouTube bloqueando, es el servidor autolimitándose para
  /// proteger el presupuesto de IP compartido. A diferencia de [extraction],
  /// este caso sí sabe con certeza cuánto esperar:
  /// [DownloadSourceException.retryAfterSeconds] trae el valor exacto que
  /// calculó el servidor a partir de su propia ventana. Ver
  /// docs/arquitectura_servidor_hibrido.md, sección 5.
  quotaExceeded,

  /// El muro anti-bot de YouTube específicamente ("Sign in to confirm you're
  /// not a bot"), distinto de [extraction] genérico (HTTP 503, no 502 — ver
  /// `server/app/ytdlp_client.py`'s `AntiBotBlockError`). Temporal, pero con
  /// una ventana de recuperación medida en **20-40+ minutos**
  /// (`docs/investigacion_muro_antibot.md`), no los segundos que basta
  /// esperar tras un [extraction] cualquiera — el backoff corto de la cola
  /// se agotaría mucho antes de que esto se despeje, descartando de la cola
  /// canciones perfectamente descargables. Igual que con [quotaExceeded],
  /// nunca se inventa un tiempo exacto acá: no hay `Retry-After` real que
  /// mandar, sólo el rango medido.
  antiBotBlocked,

  /// El servidor no puede atender ahora (503 con `Retry-After`: p. ej. la
  /// verificación de sesión no responde). Temporal; no gasta reintentos.
  serviceUnavailable,

  /// Todos los servidores se quedaron sin ancho de banda del mes (el
  /// alojamiento los suspende hasta el mes siguiente). [message] ya trae el
  /// texto con el tiempo que falta.
  serverCapacityExhausted,

  /// El servidor rechazó la canción por pesar más de lo que acepta (422 con
  /// `reason: song_too_long`). Definitivo: reintentar no la hace más corta.
  songTooLong,

  /// El servidor retiró este contenido por una reclamación de derechos de
  /// autor (451, `reason: blocked_legal`). Definitivo: no se reintenta ni se
  /// busca un reemplazo.
  blockedLegal,

  /// El usuario canceló.
  cancelled,
}

class DownloadSourceException implements Exception {
  final DownloadSourceErrorKind kind;
  final String message;

  /// Sólo tiene valor para [DownloadSourceErrorKind.quotaExceeded]: los
  /// segundos exactos que el servidor calculó a partir de su propia ventana
  /// de límite (cabecera `Retry-After`, RFC 9110). Nunca se inventa un
  /// número aquí — si el servidor no lo mandó, queda en null y quien lo
  /// consuma debe mostrar un mensaje aproximado, no una cuenta atrás falsa.
  final int? retryAfterSeconds;

  /// Estado HTTP cuando el error vino de una respuesta; sólo sirve para el
  /// código de reporte.
  final int? statusCode;

  /// `reason` estable del cuerpo del error, si el servidor lo envía.
  final String? reason;

  const DownloadSourceException(this.kind, this.message, {this.retryAfterSeconds, this.statusCode, this.reason});

  /// True si reintentar más tarde tiene alguna posibilidad de funcionar.
  ///
  /// Es lo único que la cola mira para decidir entre reintentar y descartar,
  /// así que clasificar mal un error se paga de una de dos formas: gastar el
  /// presupuesto de reintentos en un vídeo que ya no existe, o tirar una
  /// canción perfectamente descargable por un corte de red de un segundo.
  bool get isRetryable =>
      kind == DownloadSourceErrorKind.network ||
      kind == DownloadSourceErrorKind.extraction ||
      kind == DownloadSourceErrorKind.quotaExceeded ||
      kind == DownloadSourceErrorKind.antiBotBlocked ||
      kind == DownloadSourceErrorKind.serviceUnavailable ||
      kind == DownloadSourceErrorKind.serverCapacityExhausted;

  /// Frase para el usuario (español, tuteo), sin texto crudo del servidor ni
  /// de la excepción original: [message] queda para `print` y para
  /// `lastError` en la base. Sólo los cupos y la capacidad muestran el texto
  /// que el servidor/pool redactó para personas, y aun así filtrado por
  /// [safeServerText].
  String get userMessage =>
      downloadErrorMessage(kind, serverText: message, retryAfterSeconds: retryAfterSeconds, reason: reason);

  /// Código corto para reportar (`E-DL-EXT-502`). Nunca lleva detalle.
  String get code => downloadErrorCode(kind, statusCode: statusCode);

  /// [userMessage] más la línea "Código: ..." — lo que va a la pantalla.
  String get reportMessage => withReportCode(userMessage, code);

  @override
  String toString() => 'DownloadSourceException($kind): $message'
      '${retryAfterSeconds != null ? ' (retryAfter=${retryAfterSeconds}s)' : ''}';
}

/// Qué falló al probar la conexión, para mostrarlo en el idioma de la app.
enum DownloadProbeProblem { noServer, unreachable, timeout, capacity, serviceDown, keyInvalid, potDown }

/// Estado del servidor, para el botón "Probar conexión" de Ajustes.
class DownloadSourceStatus {
  final bool reachable;
  final bool authenticated;
  final String? version;

  /// True si el proveedor de PO tokens responde. Si es false el servidor
  /// arranca igual pero la mayoría de descargas fallarán con 403, así que
  /// merece avisar en vez de dejar que el usuario lo descubra descargando.
  final bool potProviderReachable;
  final String detail;

  /// Causa del fallo; la pantalla la localiza en vez de mostrar [detail].
  final DownloadProbeProblem? problem;
  final int? statusCode;

  const DownloadSourceStatus({
    required this.reachable,
    required this.authenticated,
    required this.version,
    required this.potProviderReachable,
    required this.detail,
    this.problem,
    this.statusCode,
  });
}

typedef ProgressCallback = void Function(int receivedBytes, int? totalBytes);
typedef CancellationCheck = bool Function();

abstract class DownloadSource {
  /// Metadata de un vídeo suelto.
  Future<RemoteTrack> resolve(String url);

  /// Expande una playlist a sus pistas.
  Future<RemotePlaylist> resolvePlaylist(String url);

  /// Busca por texto.
  Future<List<RemoteTrack>> search(String query, {int limit});

  /// Descarga el audio de [trackId] a [destPath].
  ///
  /// [onProgress] puede tardar en recibir su primera llamada: el servidor
  /// baja el vídeo antes de empezar a transferir.
  Future<void> fetchAudio(
    String trackId,
    String destPath, {
    ProgressCallback? onProgress,
    CancellationCheck? isCancelled,
  });

  /// Diagnóstico para Ajustes. No lanza: devuelve el estado.
  Future<DownloadSourceStatus> probe();

  /// Explorar: [country] en mayúsculas de 2 letras, o null para el del servidor.
  /// [fresh] pide saltarse la caché del servidor (refresco manual).
  Future<List<ExploreShelf>> exploreHome({String? country, bool fresh = false});
  Future<List<ExplorePlaylist>> exploreCharts({String? country, bool fresh = false});
  Future<List<ExploreAlbum>> exploreNewReleases({String? country, bool fresh = false});
  Future<List<ExploreMoodSection>> exploreMoods({String? country, bool fresh = false});
  Future<List<ExplorePlaylist>> exploreMood(String params, {String? country});
  Future<ExploreCollection> explorePlaylist(String playlistId);
  Future<ExploreCollection> exploreAlbum(String browseId);
  Future<List<RemoteTrack>> exploreRadio(String seedVideoId);
  Future<ExploreArtist> exploreArtist(String channelId);
  Future<List<ExploreArtistHit>> exploreArtistSearch(String query);

  /// Búsqueda filtrada de listas públicas, álbumes o artistas.
  Future<ExploreSearchResults> exploreSearch(String query, ExploreSearchKind kind, {String? country});
}
