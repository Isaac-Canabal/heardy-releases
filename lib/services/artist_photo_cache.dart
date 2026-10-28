import 'dart:async';
import 'dart:collection';

import '../models/explore.dart';
import 'artist_resolver.dart';
import 'explore_logic.dart';

/// Fotos de artista para listas que sólo conocen el nombre (Estadísticas).
/// Usa la misma búsqueda de artistas que Explorar ([resolveArtistHit]) y
/// recuerda el resultado en memoria por nombre normalizado, así que cada
/// artista se busca una vez por sesión de la app aunque la lista se
/// reconstruya. Nunca lanza: sin foto, sin red o sin sesión devuelve `null` y
/// quien llama deja su marcador.
class ArtistPhotoCache {
  final Future<List<ExploreArtistHit>> Function(String query) _search;

  /// Explorar va por el servidor y exige sesión verificada; mientras esto sea
  /// `false` no se busca y tampoco se recuerda nada, para que al iniciar
  /// sesión las fotos aparezcan sin reiniciar la app.
  final bool Function() _isAvailable;
  final int maxConcurrent;

  /// Un fallo de red se recuerda este tiempo: reabrir Estadísticas sin
  /// conexión no debe disparar otra tanda de peticiones fallidas.
  final Duration failureCooldown;
  final DateTime Function() _now;

  final Map<String, String> _resolved = {};
  final Map<String, DateTime> _failedAt = {};
  final Map<String, Future<String?>> _inFlight = {};
  final Queue<Completer<void>> _waiting = Queue();
  int _active = 0;

  ArtistPhotoCache({
    required Future<List<ExploreArtistHit>> Function(String query) search,
    bool Function()? isAvailable,
    this.maxConcurrent = 3,
    this.failureCooldown = const Duration(minutes: 5),
    DateTime Function()? now,
  })  : _search = search,
        _isAvailable = isAvailable ?? (() => true),
        _now = now ?? DateTime.now;

  /// La URL ya resuelta, sin red. `null` si no hay foto o aún no se buscó.
  String? cached(String name) {
    final url = _resolved[normalizeArtistName(name.trim())];
    return (url == null || url.isEmpty) ? null : url;
  }

  Future<String?> photoFor(String name) {
    final query = name.trim();
    final key = normalizeArtistName(query);
    if (key.isEmpty) return Future.value(null);
    final known = _resolved[key];
    if (known != null) return Future.value(known.isEmpty ? null : known);
    final failed = _failedAt[key];
    if (failed != null && _now().difference(failed) < failureCooldown) return Future.value(null);
    final running = _inFlight[key];
    if (running != null) return running;
    if (!_isAvailable()) return Future.value(null);
    // Cuerpo con llaves: `remove` devuelve este mismo Future y `whenComplete`
    // esperaría a sí mismo.
    final future = _lookup(key, query).whenComplete(() {
      _inFlight.remove(key);
    });
    _inFlight[key] = future;
    return future;
  }

  Future<String?> _lookup(String key, String query) async {
    await _acquire();
    try {
      final hit = await resolveArtistHit(query, _search);
      final url = hit?.thumbnailUrl.trim() ?? '';
      _resolved[key] = url;
      _failedAt.remove(key);
      return url.isEmpty ? null : url;
    } catch (_) {
      _failedAt[key] = _now();
      return null;
    } finally {
      _release();
    }
  }

  Future<void> _acquire() async {
    if (_active < maxConcurrent) {
      _active++;
      return;
    }
    final turn = Completer<void>();
    _waiting.add(turn);
    await turn.future;
  }

  void _release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
    } else {
      _active--;
    }
  }
}
