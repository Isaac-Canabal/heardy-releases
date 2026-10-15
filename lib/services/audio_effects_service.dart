import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_log.dart';
import 'windows_waveform_source.dart' show locateBundledFfmpeg;

enum EffectsPlatform { android, windows, other }

EffectsPlatform get _currentPlatform => Platform.isAndroid
    ? EffectsPlatform.android
    : Platform.isWindows
        ? EffectsPlatform.windows
        : EffectsPlatform.other;

/// Sonoridad integrada (LUFS) y pico real (dBFS) de una pista.
class LoudnessInfo {
  final double integratedLufs;
  final double truePeakDb;
  const LoudnessInfo(this.integratedLufs, this.truePeakDb);
}

const double levelerTargetLufs = -16;
const double levelerPeakCeilingDb = -1;
const double levelerMaxBoostDb = 12;
const double levelerMaxCutDb = -12;

final _summaryLoudness = RegExp(r'Integrated loudness:\s*I:\s*(-?[\d.]+|-?inf)\s*LUFS');
final _summaryPeak = RegExp(r'True peak:\s*Peak:\s*(-?[\d.]+|-?inf)\s*dBFS');

/// Lee el resumen que imprime `ffmpeg -af ebur128=peak=true`. null si falta o
/// si es un silencio total (`-inf`), que no se puede nivelar.
LoudnessInfo? parseEbur128Summary(String output) {
  final summaryAt = output.lastIndexOf('Summary:');
  if (summaryAt < 0) return null;
  final summary = output.substring(summaryAt);
  final i = double.tryParse(_summaryLoudness.firstMatch(summary)?.group(1) ?? '');
  final p = double.tryParse(_summaryPeak.firstMatch(summary)?.group(1) ?? '');
  if (i == null || p == null || !i.isFinite || !p.isFinite) return null;
  return LoudnessInfo(i, p);
}

/// Ganancia estática (dB) que acerca la pista al objetivo sin que el pico real
/// pase del techo, acotada para que una pista casi muda no se dispare.
double levelerGainDb(LoudnessInfo info) {
  final wanted = levelerTargetLufs - info.integratedLufs;
  final headroom = levelerPeakCeilingDb - info.truePeakDb;
  final gain = math.min(wanted, headroom);
  return gain.clamp(levelerMaxCutDb, levelerMaxBoostDb).toDouble();
}

/// Propiedades de mpv para la ganancia de la pista actual. El libmpv que
/// empaqueta `media_kit` es de sólo audio y no trae ningún filtro de
/// libavfilter (ni `dynaudnorm`, ni `volume`, ni `alimiter`): un `af` con ellos
/// deja el reproductor sin audio. En cambio `replaygain-fallback` aplica una
/// ganancia fija en dB a los archivos sin etiqueta, que es justo lo que hace
/// falta. `replaygain-clip=no` porque el tope por pico ya lo pone
/// [levelerGainDb].
Map<String, String> buildWindowsLevelerProperties({required bool enabled, required double gainDb}) {
  if (!enabled) return {'replaygain': 'no'};
  return {
    'replaygain': 'track',
    'replaygain-fallback': gainDb.toStringAsFixed(1),
    'replaygain-clip': 'no',
  };
}

/// Quien tenía "Normalizar volumen" (ReplayGain, ya retirado) pedía volumen
/// parejo: se le enciende "Estabilizar audio" una sola vez, sólo si nunca
/// eligió nada ahí.
bool shouldMigrateNormalizeToStabilize({
  required bool? legacyNormalize,
  required bool? storedStabilize,
}) {
  return legacyNormalize == true && storedStabilize == null;
}

abstract class LoudnessAnalyzer {
  Future<LoudnessInfo?> analyze(String path);
}

typedef FfmpegRunner = Future<String?> Function(String exe, List<String> args);

Future<String?> _runFfmpeg(String exe, List<String> args) async {
  final result = await Process.run(exe, args, stderrEncoding: systemEncoding)
      .timeout(const Duration(seconds: 90));
  return result.stderr as String?;
}

/// Mide la sonoridad con el ffmpeg LGPL que ya se empaqueta para la onda
/// (`ebur128` decodifica ~200x más rápido que el tiempo real).
class FfmpegLoudnessAnalyzer implements LoudnessAnalyzer {
  FfmpegLoudnessAnalyzer({String? Function()? locator, FfmpegRunner? runner, this.maxCached = 200})
      : _locator = locator ?? locateBundledFfmpeg,
        _runner = runner ?? _runFfmpeg;

  final String? Function() _locator;
  final FfmpegRunner _runner;
  final int maxCached;
  final Map<String, LoudnessInfo> _cache = {};

  @override
  Future<LoudnessInfo?> analyze(String path) async {
    final cached = _cache[path];
    if (cached != null) return cached;
    final exe = _locator();
    if (exe == null) {
      appLog('AudioEffects: ffmpeg no está, no se puede medir la sonoridad');
      return null;
    }
    try {
      final out = await _runner(exe, [
        '-hide_banner', '-nostdin', '-nostats', '-vn',
        '-i', path,
        '-af', 'ebur128=peak=true',
        '-f', 'null', '-',
      ]);
      final info = out == null ? null : parseEbur128Summary(out);
      if (info == null) return null;
      if (_cache.length >= maxCached) _cache.remove(_cache.keys.first);
      _cache[path] = info;
      return info;
    } catch (e) {
      appLog('AudioEffects: no se pudo medir la sonoridad (${e.runtimeType})');
      return null;
    }
  }
}

/// Efecto de Android que nivela el volumen; vive en Kotlin porque
/// `DynamicsProcessing` no está en `just_audio`.
abstract class VolumeLevelerChannel {
  /// Devuelve qué motor quedó activo (`dynamics`, `loudness`) o null si
  /// ninguno pudo engancharse.
  Future<String?> enable(int sessionId);
  Future<void> disable();
}

class MethodVolumeLevelerChannel implements VolumeLevelerChannel {
  static const _channel = MethodChannel('heardy/volume_leveler');

  @override
  Future<String?> enable(int sessionId) async {
    try {
      return await _channel.invokeMethod<String>('enable', {'sessionId': sessionId});
    } on PlatformException catch (e) {
      appLog('AudioEffects: el nivelador falló (${e.code})');
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<void> disable() async {
    try {
      await _channel.invokeMethod<void>('disable');
    } on PlatformException catch (e) {
      appLog('AudioEffects: no se pudo liberar el nivelador (${e.code})');
    } on MissingPluginException {
      return;
    }
  }
}

typedef MpvPropertySetter = Future<bool> Function(Map<String, String> properties);

Future<bool> _setMpvProperties(Map<String, String> properties) async {
  final platform = JustAudioMediaKit.rawPlayer?.platform;
  if (platform is! NativePlayer) return false;
  for (final e in properties.entries) {
    await platform.setProperty(e.key, e.value);
  }
  return true;
}

/// "Estabilizar audio": en Android un compresor/limitador de sistema
/// (`DynamicsProcessing`, con `LoudnessEnhancer` de respaldo) enganchado a la
/// sesión de audio del reproductor; en Windows una ganancia por pista medida
/// con ffmpeg y aplicada vía mpv (ver [buildWindowsLevelerProperties]). Todo
/// lo de plataforma entra por constructor para poder probarlo sin dispositivo.
class AudioEffectsService with ChangeNotifier {
  static const _stabilizeKey = 'audio_fx_stabilize_enabled';
  static const _legacyNormalizeKey = 'normalize_volume';

  final EffectsPlatform _platform;
  final VolumeLevelerChannel _leveler;
  final LoudnessAnalyzer _analyzer;
  final MpvPropertySetter _setMpv;
  final List<Duration> _retryDelays;
  final List<StreamSubscription<Object?>> _subs = [];

  bool _stabilizeEnabled = false;
  bool _loaded = false;
  bool _disposed = false;
  int? _sessionId;
  String? _trackPath;
  int _applyToken = 0;

  AudioEffectsService({
    required Stream<int?> androidSessionIds,
    required Stream<String?> trackPaths,
    EffectsPlatform? platform,
    VolumeLevelerChannel? leveler,
    LoudnessAnalyzer? analyzer,
    MpvPropertySetter? setMpvProperties,
    List<Duration>? retryDelays,
  })  : _platform = platform ?? _currentPlatform,
        _leveler = leveler ?? MethodVolumeLevelerChannel(),
        _analyzer = analyzer ?? FfmpegLoudnessAnalyzer(),
        _setMpv = setMpvProperties ?? _setMpvProperties,
        _retryDelays = retryDelays ??
            const [
              Duration(milliseconds: 250),
              Duration(milliseconds: 500),
              Duration(seconds: 1),
              Duration(seconds: 2),
              Duration(seconds: 4),
            ] {
    _subs.add(androidSessionIds.listen((id) {
      _sessionId = (id == null || id <= 0) ? null : id;
      if (_loaded) _apply();
    }));
    _subs.add(trackPaths.listen((path) {
      _trackPath = path;
      if (_loaded) _apply();
    }));
    _load();
  }

  bool get stabilizeEnabled => _stabilizeEnabled;
  bool get isLoaded => _loaded;

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getBool(_stabilizeKey);
    if (shouldMigrateNormalizeToStabilize(
      legacyNormalize: prefs.getBool(_legacyNormalizeKey),
      storedStabilize: stored,
    )) {
      _stabilizeEnabled = true;
      await prefs.setBool(_stabilizeKey, true);
    } else {
      _stabilizeEnabled = stored ?? false;
    }
    await prefs.remove(_legacyNormalizeKey);
    _loaded = true;
    notifyListeners();
    await _apply();
  }

  Future<void> setStabilizeEnabled(bool enabled) async {
    _stabilizeEnabled = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_stabilizeKey, enabled);
    await _apply();
  }

  Future<void> _apply() async {
    switch (_platform) {
      case EffectsPlatform.android:
        await _applyAndroid();
      case EffectsPlatform.windows:
        await _applyWindows();
      case EffectsPlatform.other:
        return;
    }
  }

  Future<void> _applyAndroid() async {
    if (!_stabilizeEnabled) {
      await _leveler.disable();
      return;
    }
    final session = _sessionId;
    if (session == null) return;
    final engine = await _leveler.enable(session);
    appLog('AudioEffects: nivelador de Android -> ${engine ?? 'sin motor'}');
  }

  Future<void> _applyWindows() async {
    final token = ++_applyToken;
    var gainDb = 0.0;
    final path = _trackPath;
    if (_stabilizeEnabled && path != null) {
      final info = await _analyzer.analyze(path);
      if (token != _applyToken) return;
      if (info != null) gainDb = levelerGainDb(info);
    }
    final props = buildWindowsLevelerProperties(enabled: _stabilizeEnabled, gainDb: gainDb);
    for (var attempt = 0;; attempt++) {
      if (_disposed || token != _applyToken) return;
      if (await _setMpv(props)) return;
      if (attempt >= _retryDelays.length) {
        appLog('AudioEffects: el reproductor de escritorio aún no está listo, no se aplicó el nivelador');
        return;
      }
      await Future<void>.delayed(_retryDelays[attempt]);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final s in _subs) {
      s.cancel();
    }
    if (_platform == EffectsPlatform.android) _leveler.disable();
    super.dispose();
  }
}
