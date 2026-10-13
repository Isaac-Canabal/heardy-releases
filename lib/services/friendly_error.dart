/// Traduce cualquier fallo a algo que una persona pueda leer: una frase clara
/// de qué pasó y qué hacer, más un código corto (`E-<ÁREA>-<TIPO>[-<HTTP>]`)
/// que puede citar al reportarlo.
///
/// Regla de la casa: el texto crudo de una excepción (SDK, HTTP, yt-dlp,
/// sockets, rutas) va al `print`/log y a `lastError` de la base, NUNCA a la
/// pantalla ni al código. El código sólo se construye con el tipo del error y
/// el estado HTTP, jamás con detalle del servidor, URLs, ids o datos del
/// usuario.
///
/// Todo lo de este archivo es puro (sin `BuildContext`) para poder probarlo
/// sin renderizar nada; [localizedFriendlyError] es la única excepción: recibe
/// el [AppLocalizations] ya resuelto por la pantalla.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import '../l10n/app_localizations.dart';
import 'cloud_source.dart';
import 'download_source.dart';
import 'firebase_rest_auth.dart';

/// Un error ya presentable: frase + código.
class FriendlyError {
  final String message;
  final String code;

  const FriendlyError(this.message, this.code);

  /// Frase y, en una segunda línea, el código para reportar.
  String get report => withReportCode(message, code);

  @override
  String toString() => report;
}

/// Excepción con mensaje ya redactado para el usuario (los servicios no
/// tienen `BuildContext`, así que el texto va en español aquí).
class FriendlyException implements Exception {
  final String message;
  final String code;

  const FriendlyException(this.message, this.code);

  @override
  String toString() => message;
}

/// El `reason` estable que el servidor añade al cuerpo de algunos errores;
/// `null` si el cuerpo no es JSON o no lo trae (servidores anteriores).
String? reasonFromBody(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map && decoded['reason'] is String) return decoded['reason'] as String;
  } catch (_) {
    // Cuerpo no-JSON: no hay razón.
  }
  return null;
}

String reportCodeLine(String code) => 'Código: $code';

String withReportCode(String message, String code) => '$message\n${reportCodeLine(code)}';

// ---------------------------------------------------------------------------
// Texto del servidor
// ---------------------------------------------------------------------------

const _voseoPairs = <(String, String)>[
  ('Volvé', 'Vuelve'),
  ('Esperá', 'Espera'),
  ('Probá', 'Prueba'),
  ('Elegí', 'Elige'),
  ('Intentá', 'Inténtalo'),
  ('Revisá', 'Revisa'),
  ('Configurá', 'Configura'),
  ('Agregá', 'Agrega'),
  ('Podés', 'Puedes'),
  ('Tenés', 'Tienes'),
  ('Querés', 'Quieres'),
];

const _letters = 'A-Za-zÁÉÍÓÚáéíóúüñÑ';

// El word-boundary de Dart no trata las vocales acentuadas como letras, así que se
// delimita la palabra con lookarounds explícitos.
final _voseo = <RegExp, String>{
  for (final (from, to) in _voseoPairs) ...{
    RegExp('(?<![$_letters])$from(?![$_letters])'): to,
    RegExp('(?<![$_letters])${from.toLowerCase()}(?![$_letters])'): to.toLowerCase(),
  },
};

/// Pasa a tuteo el voseo que pueda traer un texto escrito en el servidor.
String tuteo(String text) {
  var out = text;
  _voseo.forEach((re, replacement) => out = out.replaceAll(re, replacement));
  return out;
}

final _technicalText = RegExp(
  r'[\[\]{}<>#]|://|\\|file:|(^|\s)/[\w.-]+/|\d+/\d+|'
  r'exception|traceback|error|errno|socket|timeout|yt-dlp|stack',
  caseSensitive: false,
);

// Códigos de SDK en MAYÚSCULAS_CON_GUIONES: sensible a mayúsculas a propósito.
final _sdkCode = RegExp(r'\b[A-Z][A-Z0-9]*_[A-Z0-9_]+\b');

final _englishText = RegExp(
  r'\b(the|is|are|not|this|that|failed|unable|please|confirm|bot|sign|private|requested|available)\b',
  caseSensitive: false,
);

/// Devuelve [raw] en tuteo si parece una frase escrita para personas, o
/// `null` si huele a texto técnico (JSON, listas, rutas, códigos de SDK,
/// inglés de yt-dlp...). Quien llame cae entonces a su mensaje fijo.
String? safeServerText(String? raw) {
  if (raw == null) return null;
  final text = raw.trim();
  if (text.isEmpty || text.length > 240) return null;
  final lower = text.toLowerCase();
  if (lower == 'sin detalle' || lower.contains('respuesta inesperada')) return null;
  if (_technicalText.hasMatch(text)) return null;
  if (_sdkCode.hasMatch(text)) return null;
  if (_englishText.hasMatch(text)) return null;
  return tuteo(text);
}

// ---------------------------------------------------------------------------
// Descargas
// ---------------------------------------------------------------------------

String downloadErrorCode(DownloadSourceErrorKind kind, {int? statusCode}) {
  final short = switch (kind) {
    DownloadSourceErrorKind.notConfigured => 'CFG',
    DownloadSourceErrorKind.network => 'NET',
    DownloadSourceErrorKind.unauthorized => 'AUTH',
    DownloadSourceErrorKind.badRequest => 'BAD',
    DownloadSourceErrorKind.extraction => 'EXT',
    DownloadSourceErrorKind.notFound => 'NF',
    DownloadSourceErrorKind.unsupportedMedia => 'MEDIA',
    DownloadSourceErrorKind.quotaExceeded => 'QUOTA',
    DownloadSourceErrorKind.dailyQuotaExceeded => 'DQUOTA',
    DownloadSourceErrorKind.antiBotBlocked => 'BOT',
    DownloadSourceErrorKind.serviceUnavailable => 'UNAVAIL',
    DownloadSourceErrorKind.serverCapacityExhausted => 'CAP',
    DownloadSourceErrorKind.songTooLong => 'LONG',
    DownloadSourceErrorKind.blockedLegal => 'LEGAL',
    DownloadSourceErrorKind.cancelled => 'CANCEL',
  };
  return 'E-DL-$short${statusCode != null ? '-$statusCode' : ''}';
}

/// "3 minutos", "1 minuto", "unos segundos".
String _formatWait(int seconds) {
  if (seconds < 60) return 'unos segundos';
  final minutes = (seconds / 60).ceil();
  return minutes == 1 ? '1 minuto' : '$minutes minutos';
}

String downloadErrorMessage(
  DownloadSourceErrorKind kind, {
  String serverText = '',
  int? retryAfterSeconds,
  String? reason,
}) {
  switch (kind) {
    case DownloadSourceErrorKind.notConfigured:
      // Dos causas distintas comparten el tipo: sin servidor configurado, o
      // sin carpeta de biblioteca elegida. El texto de origen es una
      // constante interna, pero sólo se usa para distinguirlas.
      return serverText.toLowerCase().contains('carpeta')
          ? 'Elige primero una carpeta para tu biblioteca en Ajustes.'
          : 'Configura la dirección del servidor de descargas en Ajustes.';
    case DownloadSourceErrorKind.network:
      return 'No se pudo contactar con el servidor de descargas. Revisa tu conexión a internet; '
          'si el servidor llevaba un rato inactivo, puede tardar un minuto en arrancar. '
          'Se reintentará solo.';
    case DownloadSourceErrorKind.unauthorized:
      return 'Tu sesión no es válida o ha caducado. Cierra sesión, vuelve a iniciarla e inténtalo de nuevo.';
    case DownloadSourceErrorKind.badRequest:
      return 'No se pudo procesar esa solicitud. Comprueba que el enlace sea correcto e inténtalo de nuevo.';
    case DownloadSourceErrorKind.extraction:
      return 'No se pudo obtener el audio en este momento. Se reintentará solo; '
          'si sigue fallando, inténtalo más tarde.';
    case DownloadSourceErrorKind.notFound:
      return 'Ese contenido no se puede descargar (borrado, privado, restringido, en directo o demasiado largo).';
    case DownloadSourceErrorKind.unsupportedMedia:
      return 'Ese vídeo no tiene una pista de audio compatible';
    case DownloadSourceErrorKind.quotaExceeded:
      if (reason == 'rate_limited') {
        return 'Estás haciendo demasiadas acciones seguidas. Espera un momento e inténtalo de nuevo.';
      }
      return retryAfterSeconds != null && retryAfterSeconds >= 60
          ? 'El servidor está ocupado. Se reintentará en ${_formatWait(retryAfterSeconds)}.'
          : 'El servidor está ocupado, reintentando en unos segundos.';
    case DownloadSourceErrorKind.dailyQuotaExceeded:
      return safeServerText(serverText) ?? 'Has llegado a tu cupo de descargas. Vuelve más tarde.';
    case DownloadSourceErrorKind.antiBotBlocked:
      // Sin cifra exacta: 20-40 min es lo único medido de verdad.
      return 'YouTube bloqueó temporalmente al servidor. Puede tardar entre 20 y 40 minutos; se reintentará solo.';
    case DownloadSourceErrorKind.serviceUnavailable:
      if (reason == 'auth_unavailable') {
        return 'No se pudo comprobar tu sesión ahora mismo. Se reintentará en unos segundos.';
      }
      if (reason == 'not_configured') return 'El servidor todavía no está listo. Inténtalo de nuevo más tarde.';
      return 'El servicio no está disponible ahora mismo. Inténtalo en unos minutos.';
    case DownloadSourceErrorKind.serverCapacityExhausted:
      return safeServerText(serverText) ??
          'Los servidores han agotado su capacidad de este mes. Vuelve a intentarlo más adelante.';
    case DownloadSourceErrorKind.songTooLong:
      return 'Esta canción es demasiado larga para descargarla desde el servidor.';
    case DownloadSourceErrorKind.blockedLegal:
      return 'Este contenido no está disponible por una reclamación de derechos de autor.';
    case DownloadSourceErrorKind.cancelled:
      return 'Descarga cancelada';
  }
}

// ---------------------------------------------------------------------------
// Nube (cuenta, biblioteca, amigos)
// ---------------------------------------------------------------------------

String _cloudKindShort(CloudSourceErrorKind kind) => switch (kind) {
      CloudSourceErrorKind.network => 'NET',
      CloudSourceErrorKind.unauthorized => 'AUTH',
      CloudSourceErrorKind.notFound => 'NF',
      CloudSourceErrorKind.conflict => 'CONF',
      CloudSourceErrorKind.quotaExceeded => 'QUOTA',
      CloudSourceErrorKind.needsUsername => 'USER',
      CloudSourceErrorKind.badRequest => 'BAD',
      CloudSourceErrorKind.serverCapacityExhausted => 'CAP',
      CloudSourceErrorKind.serviceUnavailable => 'UNAVAIL',
      CloudSourceErrorKind.serverError => 'SRV',
    };

String cloudErrorCode(CloudSourceErrorKind kind, {int? statusCode}) =>
    'E-CL-${_cloudKindShort(kind)}${statusCode != null ? '-$statusCode' : ''}';

/// Mensaje fijo por tipo, sin texto del servidor (lo usa también la
/// sincronización, donde un detalle como "Ese nombre ya está en uso" no
/// tendría sentido).
String cloudFixedMessage(CloudSourceErrorKind kind, {bool isVersionConflict = false, String? reason}) {
  switch (kind) {
    case CloudSourceErrorKind.network:
      return 'No se pudo contactar con el servidor. Revisa tu conexión a internet e inténtalo de nuevo.';
    case CloudSourceErrorKind.unauthorized:
      return 'Tu sesión ha caducado o no es válida. Inicia sesión de nuevo e inténtalo otra vez.';
    case CloudSourceErrorKind.notFound:
      return 'No encontramos lo que buscas. Comprueba el nombre e inténtalo de nuevo.';
    case CloudSourceErrorKind.conflict:
      return isVersionConflict
          ? 'Tu biblioteca cambió en otro dispositivo mientras se sincronizaba. Se volverá a intentar en la próxima sincronización.'
          : 'Ese cambio choca con otro que ya existe. Revisa los datos e inténtalo de nuevo.';
    case CloudSourceErrorKind.quotaExceeded:
      if (reason == 'rate_limited') {
        return 'Estás haciendo demasiadas acciones seguidas. Espera un momento e inténtalo de nuevo.';
      }
      if (reason == 'busy') return 'El servidor está ocupado. Inténtalo de nuevo en unos segundos.';
      return 'Has alcanzado el límite de uso de hoy para esta función. Inténtalo más tarde.';
    case CloudSourceErrorKind.needsUsername:
      return 'Elige un nombre de usuario para poder usar esta función.';
    case CloudSourceErrorKind.badRequest:
      return 'No se pudo procesar la solicitud. Inténtalo de nuevo; si el problema sigue, actualiza la app.';
    case CloudSourceErrorKind.serverCapacityExhausted:
      return 'Los servidores han agotado su capacidad de este mes. Vuelve a intentarlo más adelante.';
    case CloudSourceErrorKind.serviceUnavailable:
      if (reason == 'auth_unavailable') {
        return 'No se pudo comprobar tu sesión ahora mismo. Se reintentará en unos segundos.';
      }
      if (reason == 'not_configured') return 'El servidor todavía no está listo. Inténtalo de nuevo más tarde.';
      return 'El servicio no está disponible ahora mismo. Inténtalo en unos minutos.';
    case CloudSourceErrorKind.serverError:
      return 'El servidor tuvo un problema. Inténtalo de nuevo en unos minutos.';
  }
}

/// Mensaje para la UI. El texto del servidor sólo se muestra tal cual en los
/// tipos donde el servidor escribe frases para personas (conflicto, cupo,
/// 400, capacidad) y sólo si pasa [safeServerText].
String cloudErrorMessage(
  CloudSourceErrorKind kind,
  String serverText, {
  int? statusCode,
  bool isVersionConflict = false,
  String? reason,
}) {
  final fixed = cloudFixedMessage(kind, isVersionConflict: isVersionConflict, reason: reason);
  switch (kind) {
    case CloudSourceErrorKind.conflict:
      if (isVersionConflict) return fixed;
      return safeServerText(serverText) ?? fixed;
    case CloudSourceErrorKind.quotaExceeded:
    case CloudSourceErrorKind.serverCapacityExhausted:
      return safeServerText(serverText) ?? fixed;
    case CloudSourceErrorKind.badRequest:
      // 413/422 traen listas de campos, no frases: sólo el 400 es de personas.
      return statusCode == 400 ? (safeServerText(serverText) ?? fixed) : fixed;
    default:
      return fixed;
  }
}

// ---------------------------------------------------------------------------
// Sincronización
// ---------------------------------------------------------------------------

const _syncSteps = {
  'cuenta': ('CU', 'No se pudo conectar con tu cuenta.'),
  'historial': ('HI', 'No se pudo subir tu historial de reproducciones.'),
  'historial-nuevo': ('HN', 'No se pudo descargar tu historial de reproducciones.'),
  'biblioteca': ('BI', 'No se pudo sincronizar tu biblioteca.'),
  'presencia': ('PR', 'No se pudo actualizar «Escuchando ahora».'),
};

String syncStepShort(String step) => _syncSteps[step]?.$1 ?? 'XX';

/// Error de un paso de la sincronización: la frase dice qué falló y por qué
/// en términos de persona; el paso sólo viaja en el código
/// (`E-SY-<PASO>-<TIPO>[-<HTTP>]`).
FriendlyError friendlySyncStepError(String step, Object error) {
  final entry = _syncSteps[step];
  final sentence = entry?.$2 ?? 'No se pudo sincronizar.';
  final short = syncStepShort(step);
  if (error is CloudSourceException) {
    final status = error.statusCode;
    return FriendlyError(
      '$sentence ${cloudFixedMessage(error.kind, isVersionConflict: error.isVersionConflict)}',
      'E-SY-$short-${_cloudKindShort(error.kind)}${status != null ? '-$status' : ''}',
    );
  }
  final generic = _classifyGeneric(error);
  return switch (generic) {
    _GenericKind.network => FriendlyError(
        '$sentence Revisa tu conexión a internet e inténtalo de nuevo.',
        'E-SY-$short-NET',
      ),
    _ => FriendlyError(
        '$sentence Inténtalo de nuevo más tarde.',
        'E-SY-$short-${generic == _GenericKind.format ? 'FMT' : generic == _GenericKind.file ? 'IO' : 'UNK'}',
      ),
  };
}

// ---------------------------------------------------------------------------
// Genéricos
// ---------------------------------------------------------------------------

enum _GenericKind { network, format, file, unknown }

_GenericKind _classifyGeneric(Object error) {
  if (error is SocketException ||
      error is TimeoutException ||
      error is HandshakeException ||
      error is HttpException ||
      error is http.ClientException) {
    return _GenericKind.network;
  }
  if (error is FormatException) return _GenericKind.format;
  if (error is FileSystemException) return _GenericKind.file;
  return _GenericKind.unknown;
}

const _genericNetwork = 'No se pudo conectar. Revisa tu conexión a internet e inténtalo de nuevo.';
const _genericFormat =
    'Recibimos datos que no pudimos leer. Inténtalo de nuevo; si sigue pasando, actualiza la app.';
const _genericFile =
    'No se pudo acceder a un archivo o carpeta. Comprueba que la carpeta de tu biblioteca siga disponible.';
const _genericUnknown = 'Algo salió mal. Inténtalo de nuevo; si el problema continúa, indica este código al reportarlo.';

FriendlyError? _typedFriendly(Object error) {
  if (error is DownloadSourceException) return FriendlyError(error.userMessage, error.code);
  if (error is CloudSourceException) return FriendlyError(error.userMessage, error.code);
  if (error is FriendlyException) return FriendlyError(error.message, error.code);
  return null;
}

String _genericCode(_GenericKind kind, String area) => switch (kind) {
      _GenericKind.network => 'E-$area-NET',
      _GenericKind.format => 'E-$area-FMT',
      _GenericKind.file => 'E-FS-IO',
      _GenericKind.unknown => 'E-$area-UNK',
    };

/// Convierte cualquier excepción en frase + código sin dejar pasar su texto.
/// [area] son 2-3 letras (`GEN` por defecto, `FS` para carpeta/escaneo...).
FriendlyError friendlyFromError(Object error, {String area = 'GEN'}) {
  final typed = _typedFriendly(error);
  if (typed != null) return typed;
  final kind = _classifyGeneric(error);
  return FriendlyError(
    switch (kind) {
      _GenericKind.network => _genericNetwork,
      _GenericKind.format => _genericFormat,
      _GenericKind.file => _genericFile,
      _GenericKind.unknown => _genericUnknown,
    },
    _genericCode(kind, area),
  );
}

/// Igual que [friendlyFromError], pero los genéricos salen del idioma de la
/// app (l10n); las excepciones tipadas ya traen su frase en español.
FriendlyError localizedFriendlyError(AppLocalizations l10n, Object error, {String area = 'GEN'}) {
  if (error is DownloadSourceException) {
    return FriendlyError(
      localizedDownloadMessage(
        l10n,
        error.kind,
        serverText: error.message,
        retryAfterSeconds: error.retryAfterSeconds,
        statusCode: error.statusCode,
        reason: error.reason,
      ),
      error.code,
    );
  }
  if (error is CloudSourceException) {
    return FriendlyError(
      localizedCloudMessage(
        l10n,
        error.kind,
        error.message,
        statusCode: error.statusCode,
        isVersionConflict: error.isVersionConflict,
        retryAfterSeconds: error.retryAfterSeconds,
        reason: error.reason,
      ),
      error.code,
    );
  }
  if (error is FriendlyException) {
    final text = _localizedFriendlyException(l10n, error.code);
    if (text != null) return FriendlyError(text, error.code);
  }
  final typed = _typedFriendly(error);
  if (typed != null) return typed;
  final kind = _classifyGeneric(error);
  return FriendlyError(
    switch (kind) {
      _GenericKind.network => l10n.errorGenericNetwork,
      _GenericKind.format => l10n.errorGenericFormat,
      _GenericKind.file => l10n.errorGenericFile,
      _GenericKind.unknown => l10n.errorGenericUnknown,
    },
    _genericCode(kind, area),
  );
}

/// Frase + línea "Código: ..." lista para un `Text`/`SnackBar`.
String localizedErrorReport(AppLocalizations l10n, Object error, {String area = 'GEN'}) {
  final f = localizedFriendlyError(l10n, error, area: area);
  return '${f.message}\n${l10n.errorCodeLine(f.code)}';
}

// ---------------------------------------------------------------------------
// Mensajes en el idioma de la app
// ---------------------------------------------------------------------------

/// Texto fijo del servidor que sí se reconoce y se traduce; cualquier otro
/// `detail` no se muestra nunca.
String? _knownCloudText(AppLocalizations l10n, String serverText, {String? reason}) {
  final byReason = switch (reason) {
    'username_taken' => l10n.cloudUsernameTaken,
    'username_reserved' => l10n.cloudUsernameReserved,
    'already_friends' => l10n.cloudAlreadyFriends,
    'friends_limit' => l10n.cloudFriendLimit,
    'requests_limit' => l10n.cloudPendingLimit,
    'cannot_add_self' => l10n.cloudSelfFriend,
    _ => null,
  };
  if (byReason != null) return byReason;
  return switch (serverText.trim()) {
    'Ese nombre ya está en uso' => l10n.cloudUsernameTaken,
    'Ese nombre está reservado' => l10n.cloudUsernameReserved,
    'Ya son amigos' => l10n.cloudAlreadyFriends,
    'Llegaste al máximo de amigos' => l10n.cloudFriendLimit,
    'Demasiadas solicitudes pendientes' => l10n.cloudPendingLimit,
    'No podés agregarte a vos mismo' => l10n.cloudSelfFriend,
    _ => null,
  };
}

/// Frases fijas de servicios y proveedores que no tienen contexto de idioma:
/// se reconocen por su código de reporte.
String? _localizedFriendlyException(AppLocalizations l10n, String code) {
  if (code == 'E-PL-DUP') return l10n.playlistDuplicateName;
  if (!code.startsWith('E-SP-')) return null;
  return switch (code) {
    'E-SP-URL' => l10n.spotifyUrlInvalid,
    'E-SP-DATA' => l10n.spotifyDataMissing,
    'E-SP-TYPE' => l10n.spotifyTypeUnsupported,
    'E-SP-FMT' => l10n.spotifyFormat,
    _ => l10n.spotifyAccess,
  };
}

String _busyMessage(AppLocalizations l10n, int? retryAfterSeconds) =>
    retryAfterSeconds != null && retryAfterSeconds >= 60
        ? l10n.errorBusyMinutes((retryAfterSeconds / 60).ceil())
        : l10n.errorBusy;

/// Igual que [downloadErrorMessage], en el idioma de la app. El texto del
/// servidor solo se usa (en español) para los cupos, que son texto fijo con
/// el número del límite.
String localizedDownloadMessage(
  AppLocalizations l10n,
  DownloadSourceErrorKind kind, {
  String serverText = '',
  int? retryAfterSeconds,
  int? statusCode,
  String? reason,
}) {
  final isEs = l10n.localeName.startsWith('es');
  switch (kind) {
    case DownloadSourceErrorKind.notConfigured:
      return serverText.toLowerCase().contains('carpeta') ? l10n.dlNotConfiguredFolder : l10n.dlNotConfiguredServer;
    case DownloadSourceErrorKind.network:
      return l10n.dlNetwork;
    case DownloadSourceErrorKind.unauthorized:
      return l10n.errorSessionExpired;
    case DownloadSourceErrorKind.badRequest:
      return l10n.dlBadRequest;
    case DownloadSourceErrorKind.extraction:
      if (statusCode == 502 || statusCode == 504) return l10n.dlNetwork;
      if (statusCode == 500) return l10n.errorServerProblem;
      return l10n.dlExtraction;
    case DownloadSourceErrorKind.notFound:
      return l10n.dlNotFound;
    case DownloadSourceErrorKind.unsupportedMedia:
      return l10n.dlUnsupportedMedia;
    case DownloadSourceErrorKind.quotaExceeded:
      return reason == 'rate_limited' ? l10n.errorRateLimited : _busyMessage(l10n, retryAfterSeconds);
    case DownloadSourceErrorKind.dailyQuotaExceeded:
      return (isEs ? safeServerText(serverText) : null) ?? l10n.dlDailyQuota;
    case DownloadSourceErrorKind.antiBotBlocked:
      return l10n.dlAntiBot;
    case DownloadSourceErrorKind.serviceUnavailable:
      return _unavailableMessage(l10n, reason);
    case DownloadSourceErrorKind.serverCapacityExhausted:
      return (isEs ? safeServerText(serverText) : null) ?? l10n.dlCapacity;
    case DownloadSourceErrorKind.songTooLong:
      return l10n.dlSongTooLong;
    case DownloadSourceErrorKind.blockedLegal:
      return l10n.dlBlockedLegal;
    case DownloadSourceErrorKind.cancelled:
      return l10n.dlCancelled;
  }
}

String _unavailableMessage(AppLocalizations l10n, String? reason) => switch (reason) {
      'auth_unavailable' => l10n.errorAuthUnavailable,
      'not_configured' => l10n.errorServerNotReady,
      _ => l10n.errorServiceUnavailable,
    };

String localizedCloudFixedMessage(
  AppLocalizations l10n,
  CloudSourceErrorKind kind, {
  bool isVersionConflict = false,
  int? retryAfterSeconds,
  String? reason,
}) {
  switch (kind) {
    case CloudSourceErrorKind.network:
      return l10n.errorConnect;
    case CloudSourceErrorKind.unauthorized:
      return l10n.errorSessionExpired;
    case CloudSourceErrorKind.notFound:
      return l10n.cloudNotFound;
    case CloudSourceErrorKind.conflict:
      return isVersionConflict ? l10n.cloudConflictVersion : l10n.cloudConflict;
    case CloudSourceErrorKind.quotaExceeded:
      if (reason == 'rate_limited') return l10n.errorRateLimited;
      if (reason == 'busy') return l10n.errorBusy;
      return retryAfterSeconds != null && retryAfterSeconds < 3600
          ? _busyMessage(l10n, retryAfterSeconds)
          : l10n.cloudQuota;
    case CloudSourceErrorKind.needsUsername:
      return l10n.cloudNeedsUsername;
    case CloudSourceErrorKind.badRequest:
      return l10n.errorCheckInput;
    case CloudSourceErrorKind.serverCapacityExhausted:
      return l10n.cloudCapacity;
    case CloudSourceErrorKind.serviceUnavailable:
      return _unavailableMessage(l10n, reason);
    case CloudSourceErrorKind.serverError:
      return l10n.errorUnexpectedResponse;
  }
}

String localizedCloudMessage(
  AppLocalizations l10n,
  CloudSourceErrorKind kind,
  String serverText, {
  int? statusCode,
  bool isVersionConflict = false,
  int? retryAfterSeconds,
  String? reason,
}) {
  final fixed = localizedCloudFixedMessage(
    l10n,
    kind,
    isVersionConflict: isVersionConflict,
    retryAfterSeconds: retryAfterSeconds,
    reason: reason,
  );
  if (kind == CloudSourceErrorKind.serverError && statusCode == 500) return l10n.errorServerProblem;
  if (isVersionConflict) return fixed;
  switch (kind) {
    case CloudSourceErrorKind.conflict:
    case CloudSourceErrorKind.quotaExceeded:
    case CloudSourceErrorKind.badRequest:
      return _knownCloudText(l10n, serverText, reason: reason) ?? fixed;
    default:
      return fixed;
  }
}

/// Error de un paso de sincronización en el idioma de la app.
FriendlyError localizedSyncStepError(AppLocalizations l10n, String step, Object error) {
  final sentence = switch (step) {
    'cuenta' => l10n.syncStepAccount,
    'historial' => l10n.syncStepHistoryUp,
    'historial-nuevo' => l10n.syncStepHistoryDown,
    'biblioteca' => l10n.syncStepLibrary,
    'presencia' => l10n.syncStepPresence,
    _ => l10n.syncStepGeneric,
  };
  final short = syncStepShort(step);
  if (error is CloudSourceException) {
    final status = error.statusCode;
    final detail = localizedCloudFixedMessage(
      l10n,
      error.kind,
      isVersionConflict: error.isVersionConflict,
      retryAfterSeconds: error.retryAfterSeconds,
      reason: error.reason,
    );
    return FriendlyError(
      '$sentence $detail',
      'E-SY-$short-${_cloudKindShort(error.kind)}${status != null ? '-$status' : ''}',
    );
  }
  final generic = _classifyGeneric(error);
  return switch (generic) {
    _GenericKind.network => FriendlyError('$sentence ${l10n.syncCheckConnection}', 'E-SY-$short-NET'),
    _ => FriendlyError(
        '$sentence ${l10n.syncTryLater}',
        'E-SY-$short-${generic == _GenericKind.format ? 'FMT' : generic == _GenericKind.file ? 'IO' : 'UNK'}',
      ),
  };
}

// ---------------------------------------------------------------------------
// Autenticación
// ---------------------------------------------------------------------------

enum AuthErrorKind {
  appNotAuthorized,
  invalidEmail,
  weakPassword,
  emailInUse,
  wrongCredentials,
  userDisabled,
  tooManyRequests,
  network,
  operationNotAllowed,
  requiresRecentLogin,
  sessionExpired,
  generic,
}

String authErrorCode(AuthErrorKind kind) => switch (kind) {
      AuthErrorKind.appNotAuthorized => 'E-AU-APP',
      AuthErrorKind.invalidEmail => 'E-AU-EML',
      AuthErrorKind.weakPassword => 'E-AU-PWD',
      AuthErrorKind.emailInUse => 'E-AU-USE',
      AuthErrorKind.wrongCredentials => 'E-AU-CRD',
      AuthErrorKind.userDisabled => 'E-AU-DIS',
      AuthErrorKind.tooManyRequests => 'E-AU-MNY',
      AuthErrorKind.network => 'E-AU-NET',
      AuthErrorKind.operationNotAllowed => 'E-AU-OPN',
      AuthErrorKind.requiresRecentLogin => 'E-AU-REC',
      AuthErrorKind.sessionExpired => 'E-AU-TOK',
      AuthErrorKind.generic => 'E-AU-GEN',
    };

/// Clasifica un fallo de Firebase Auth (SDK móvil o API REST de escritorio).
AuthErrorKind authErrorKindOf(Object error) {
  // La restricción de la clave de API (paquete + SHA-1 no autorizados) no
  // llega con un código propio: se reconoce por el texto.
  final raw = error.toString().toUpperCase();
  if (raw.contains('API_KEY_ANDROID_APP_BLOCKED') || raw.contains('APP_NOT_AUTHORIZED') || raw.contains('ARE BLOCKED')) {
    return AuthErrorKind.appNotAuthorized;
  }
  if (error is SocketException || error is TimeoutException || error is http.ClientException) {
    return AuthErrorKind.network;
  }
  if (error is FirebaseAuthException) {
    switch (error.code) {
      case 'invalid-email':
      case 'malformed-email':
        return AuthErrorKind.invalidEmail;
      case 'weak-password':
        return AuthErrorKind.weakPassword;
      case 'email-already-in-use':
        return AuthErrorKind.emailInUse;
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
        return AuthErrorKind.wrongCredentials;
      case 'user-disabled':
        return AuthErrorKind.userDisabled;
      case 'too-many-requests':
        return AuthErrorKind.tooManyRequests;
      case 'network-request-failed':
        return AuthErrorKind.network;
      case 'operation-not-allowed':
        return AuthErrorKind.operationNotAllowed;
      case 'requires-recent-login':
        return AuthErrorKind.requiresRecentLogin;
      case 'user-token-expired':
      case 'invalid-user-token':
        return AuthErrorKind.sessionExpired;
    }
  }
  // Escritorio: la API REST usa sus propios códigos en MAYÚSCULAS_CON_GUIONES.
  if (error is FirebaseRestAuthException) {
    final code = error.code;
    if (code == 'EMAIL_EXISTS') return AuthErrorKind.emailInUse;
    if (code.startsWith('WEAK_PASSWORD')) return AuthErrorKind.weakPassword;
    if (code == 'INVALID_EMAIL') return AuthErrorKind.invalidEmail;
    if (code == 'EMAIL_NOT_FOUND' || code == 'INVALID_PASSWORD' || code == 'INVALID_LOGIN_CREDENTIALS') {
      return AuthErrorKind.wrongCredentials;
    }
    if (code == 'USER_DISABLED') return AuthErrorKind.userDisabled;
    if (code == 'TOO_MANY_ATTEMPTS_TRY_LATER') return AuthErrorKind.tooManyRequests;
    if (code == 'NETWORK_REQUEST_FAILED') return AuthErrorKind.network;
    if (code == 'OPERATION_NOT_ALLOWED') return AuthErrorKind.operationNotAllowed;
    if (code == 'CREDENTIAL_TOO_OLD_LOGIN_AGAIN') return AuthErrorKind.requiresRecentLogin;
    if (code == 'INVALID_ID_TOKEN' || code == 'TOKEN_EXPIRED') return AuthErrorKind.sessionExpired;
  }
  return AuthErrorKind.generic;
}
