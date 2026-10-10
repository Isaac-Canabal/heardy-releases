import 'dart:typed_data';

import 'waveform_cache.dart';
import 'waveform_logic.dart';

/// Extrae amplitudes crudas (>= 0) de un audio. Devuelve `null` si no se
/// pudo; una implementación por plataforma (Android hoy, Windows después).
abstract class WaveformSource {
  Future<List<double>?> extract(String uri);
}

/// Caché + extractor, con una sola extracción en vuelo por canción.
class WaveformRepository {
  final WaveformSource source;
  final WaveformCache cache;
  final int bars;
  final Map<String, Future<Uint8List?>> _inFlight = {};

  WaveformRepository({
    required this.source,
    required this.cache,
    this.bars = kWaveformBars,
  });

  Future<Uint8List?> load(String songId, String uri) =>
      _inFlight.putIfAbsent(songId, () async {
        try {
          final cached = await cache.read(songId);
          if (cached != null) return cached;
          final raw = await source.extract(uri);
          if (raw == null || raw.isEmpty) return null;
          final peaks = normalizeToBytes(downsampleAmplitudes(raw, bars));
          await cache.write(songId, peaks);
          return peaks;
        } catch (_) {
          return null;
        } finally {
          _inFlight.remove(songId);
        }
      });
}
