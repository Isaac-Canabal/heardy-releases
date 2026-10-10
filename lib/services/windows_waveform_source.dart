import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'app_log.dart';
import 'waveform_source.dart';

/// 8 kHz mono: 800 muestras = 100 ms por ventana de RMS.
const int kWaveformSampleRate = 8000;
const int kWaveformWindowSamples = 800;

/// Tope de audio (~30 min) para acotar la memoria; por encima, `null`.
const int kWaveformMaxSamples = kWaveformSampleRate * 60 * 30;

/// RMS por ventana de [windowSamples] muestras sobre PCM s16le mono.
///
/// Tolera chunks partidos en cualquier byte (también a mitad de muestra) y un
/// byte suelto final (se descarta). La última ventana parcial cuenta. Devuelve
/// `null` si el audio supera [maxSamples].
Future<List<double>?> pcmS16leToRms(
  Stream<List<int>> chunks, {
  int windowSamples = kWaveformWindowSamples,
  int maxSamples = kWaveformMaxSamples,
}) async {
  final out = <double>[];
  var total = 0;
  var inWindow = 0;
  var sumSq = 0.0;
  int? pendingLow;

  void addSample(int s) {
    sumSq += s * s;
    inWindow++;
    total++;
    if (inWindow == windowSamples) {
      out.add(math.sqrt(sumSq / inWindow));
      sumSq = 0;
      inWindow = 0;
    }
  }

  await for (final chunk in chunks) {
    for (final byte in chunk) {
      if (pendingLow == null) {
        pendingLow = byte;
        continue;
      }
      var v = (byte << 8) | pendingLow;
      if (v >= 0x8000) v -= 0x10000;
      pendingLow = null;
      addSample(v);
      if (total > maxSamples) return null;
    }
  }
  if (inWindow > 0) out.add(math.sqrt(sumSq / inWindow));
  return out;
}

/// Proceso hijo mínimo, para poder simularlo en tests.
abstract class WaveformProcess {
  Stream<List<int>> get stdout;
  Future<int> get exitCode;
  void kill();
}

typedef WaveformProcessStarter = Future<WaveformProcess> Function(
    String executable, List<String> args);

class _IoWaveformProcess implements WaveformProcess {
  _IoWaveformProcess(this._p) {
    // Sin drenar stderr un proceso verboso puede bloquearse.
    _p.stderr.drain<void>();
  }
  final Process _p;
  @override
  Stream<List<int>> get stdout => _p.stdout;
  @override
  Future<int> get exitCode => _p.exitCode;
  @override
  void kill() => _p.kill();
}

Future<WaveformProcess> _startProcess(String exe, List<String> args) async =>
    _IoWaveformProcess(await Process.start(exe, args));

/// `<exe>/ffmpeg/ffmpeg.exe` si existe (lo instala CMake/el instalador).
String? locateBundledFfmpeg() {
  final dir = File(Platform.resolvedExecutable).parent.path;
  final f = File('$dir\ffmpeg\ffmpeg.exe');
  return f.existsSync() ? f.path : null;
}

/// Extrae amplitudes en Windows decodificando con un ffmpeg LGPL empaquetado
/// (las descargas son M4A fragmentado, que Media Foundation no lee).
class WindowsWaveformSource implements WaveformSource {
  WindowsWaveformSource({
    String? Function()? locator,
    WaveformProcessStarter? starter,
    this.timeout = const Duration(seconds: 60),
    this.maxSamples = kWaveformMaxSamples,
  })  : _locator = locator ?? locateBundledFfmpeg,
        _starter = starter ?? _startProcess;

  final String? Function() _locator;
  final WaveformProcessStarter _starter;
  final Duration timeout;
  final int maxSamples;

  @override
  Future<List<double>?> extract(String uri) async {
    final exe = _locator();
    if (exe == null) return null;
    WaveformProcess? proc;
    try {
      proc = await _starter(exe, [
        '-v', 'error', '-nostdin',
        '-i', uri,
        '-vn', '-ac', '1', '-ar', '$kWaveformSampleRate',
        '-f', 's16le', '-',
      ]);
      final rms = await pcmS16leToRms(proc.stdout, maxSamples: maxSamples)
          .timeout(timeout);
      if (rms == null) {
        proc.kill();
        return null;
      }
      final code = await proc.exitCode.timeout(timeout);
      if (code != 0 || rms.isEmpty) return null;
      return rms;
    } on TimeoutException {
      proc?.kill();
      return null;
    } catch (e) {
      appLog('waveform ffmpeg: ${e.runtimeType}');
      proc?.kill();
      return null;
    }
  }
}
