import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Lista ordenada de servidores equivalentes (el oficial primero, los de
/// respaldo después) y cuáles de ellos se quedaron sin capacidad.
///
/// "Sin capacidad" es el tope mensual de ancho de banda del alojamiento
/// gratuito: el proveedor suspende el servicio hasta el mes siguiente y
/// responde con una página HTML, no con el JSON de la API. Un servidor así no
/// se vuelve a intentar hasta que pase el reinicio del mes, salvo una sondeada
/// cada [probeInterval] por si el dueño amplió el plan antes.
///
/// Los servidores de respaldo sólo reparten las descargas de forma
/// transparente; la sincronización de la cuenta únicamente es coherente entre
/// ellos si todos comparten la misma base de datos.
class ServerPool {
  static const probeInterval = Duration(minutes: 15);

  final List<String> urls;
  final DateTime Function() _now;
  final Map<String, _Exhaustion> _exhausted = {};

  /// `null` mientras al menos un servidor sirva; si todos están agotados, el
  /// instante más cercano en que alguno vuelve. Es lo que escucha el aviso con
  /// cuenta atrás.
  final ValueNotifier<DateTime?> allExhaustedUntil = ValueNotifier<DateTime?>(null);

  ServerPool(List<String> urls, {DateTime Function()? now})
      : urls = List.unmodifiable(urls.map((u) => u.trim()).where((u) => u.isNotEmpty)),
        _now = now ?? DateTime.now;

  /// El primer servidor utilizable ahora, o `null` si todos están agotados.
  String? current() {
    final now = _now().toUtc();
    for (final url in urls) {
      final state = _exhausted[url];
      if (state == null) return url;
      if (!now.isBefore(state.resetAt)) {
        _exhausted.remove(url);
        _refresh();
        return url;
      }
      if (now.difference(state.markedAt) >= probeInterval) {
        state.markedAt = now;
        return url;
      }
    }
    return null;
  }

  void markExhausted(String? url) {
    if (url == null) return;
    final now = _now().toUtc();
    _exhausted[url] = _Exhaustion(markedAt: now, resetAt: nextMonthStartUtc(now));
    _refresh();
  }

  void markHealthy(String? url) {
    if (url == null || _exhausted.remove(url) == null) return;
    _refresh();
  }

  void _refresh() {
    if (urls.isEmpty || !urls.every(_exhausted.containsKey)) {
      allExhaustedUntil.value = null;
      return;
    }
    allExhaustedUntil.value =
        _exhausted.values.map((s) => s.resetAt).reduce((a, b) => a.isBefore(b) ? a : b);
  }

  /// Las cuotas mensuales de los alojamientos gratuitos se renuevan con el mes
  /// de facturación, que es el mes calendario en UTC.
  static DateTime nextMonthStartUtc(DateTime now) {
    final utc = now.toUtc();
    return DateTime.utc(utc.year, utc.month + 1);
  }
}

class _Exhaustion {
  DateTime markedAt;
  final DateTime resetAt;
  _Exhaustion({required this.markedAt, required this.resetAt});
}

/// Distingue "el alojamiento suspendió el servicio por ancho de banda" de un
/// 503 de la propia API (p. ej. el muro anti-bot, que siempre viaja como JSON).
bool looksLikeCapacityExhausted(int statusCode, Map<String, String> headers, String body) {
  if (statusCode < 400) return false;
  if (_isJson(body)) return false;
  final routing = (headers['x-render-routing'] ?? '').toLowerCase();
  if (routing.contains('suspend')) return true;
  final text = body.toLowerCase();
  return text.contains('suspended') || (text.contains('bandwidth') && looksLikeHtml(body));
}

/// Una página HTML de error de un proxy, nunca apta para enseñarse tal cual.
bool looksLikeHtml(String body) {
  final start = body.trimLeft().toLowerCase();
  return start.startsWith('<!doctype') || start.startsWith('<html') || start.startsWith('<head') || start.startsWith('<body');
}

bool _isJson(String body) {
  try {
    jsonDecode(body);
    return true;
  } catch (_) {
    return false;
  }
}

/// "12 d 4 h", "5 h 20 min", "12 min": abreviaturas que valen igual en los
/// dos idiomas de la app.
String formatRemaining(Duration remaining) {
  if (remaining.isNegative || remaining.inMinutes < 1) return '< 1 min';
  final days = remaining.inDays;
  final hours = remaining.inHours % 24;
  final minutes = remaining.inMinutes % 60;
  if (days > 0) return '$days d $hours h';
  if (remaining.inHours > 0) return '${remaining.inHours} h $minutes min';
  return '$minutes min';
}

String serverCapacityMessage(DateTime resetAt, {DateTime? now}) {
  final remaining = resetAt.difference((now ?? DateTime.now()).toUtc());
  return 'El servidor llegó a su capacidad máxima. Espera a que se renueve: '
      'volverá a funcionar en ${formatRemaining(remaining)}.';
}
