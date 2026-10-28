import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_log.dart';
import 'equalizer.dart';
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

/// Ecualizador de Android: procesador dentro de ExoPlayer (fork local de
/// `just_audio`). La configuración es global del proceso, así que vale para
/// todos los reproductores, también "Escuchar".
abstract class EqualizerChannel {
  Future<bool> configure(Map<String, Object> args);
}

class MethodEqualizerChannel implements EqualizerChannel {
  static const _channel = MethodChannel('heardy/equalizer');

  @override
  Future<bool> configure(Map<String, Object> args) async {
    try {
      return await _channel.invokeMethod<bool>('configure', args) ?? false;
    } on PlatformException catch (e) {
      appLog('AudioEffects: el ecualizador falló (${e.code})');
      return false;
    } on MissingPluginException {
      return false;
    } catch (e) {
      appLog('AudioEffects: el ecualizador no respondió (${e.runtimeType})');
      return false;
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
  static const _eqEnabledKey = 'audio_fx_eq_enabled';
  static const _eqPresetKey = 'audio_fx_eq_preset';
  static const _eqGainsKey = 'audio_fx_eq_gains';

  final EffectsPlatform _platform;
  final VolumeLevelerChannel _leveler;
  final LoudnessAnalyzer _analyzer;
  final MpvPropertySetter _setMpv;
  final List<Duration> _retryDelays;
  final EqualizerChannel _equalizer;
  final Duration _eqThrottle;
  final List<StreamSubscription<Object?>> _subs = [];
  final Stopwatch _clock = Stopwatch()..start();

  bool _stabilizeEnabled = false;
  bool _loaded = false;
  bool _disposed = false;
  int? _sessionId;
  String? _trackPath;
  int _applyToken = 0;

  bool _eqEnabled = false;
  EqualizerPreset _eqPreset = EqualizerPreset.plano;
  List<double> _eqGains = flatEqualizerGains;
  Timer? _eqTimer;
  Duration? _lastEqFlush;
  bool _eqApplying = false;
  bool _eqDirty = false;

  AudioEffectsService({
    required Stream<int?> androidSessionIds,
    required Stream<String?> trackPaths,
    EffectsPlatform? platform,
    VolumeLevelerChannel? leveler,
    LoudnessAnalyzer? analyzer,
    MpvPropertySetter? setMpvProperties,
    List<Duration>? retryDelays,
    EqualizerChannel? equalizer,
    Duration equalizerThrottle = const Duration(milliseconds: 50),
  })  : _platform = platform ?? _currentPlatform,
        _leveler = leveler ?? MethodVolumeLevelerChannel(),
        _analyzer = analyzer ?? FfmpegLoudnessAnalyzer(),
        _setMpv = setMpvProperties ?? _setMpvProperties,
        _equalizer = equalizer ?? MethodEqualizerChannel(),
        _eqThrottle = equalizerThrottle,
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
      if (_loaded) {
        _apply();
        // Por si el reproductor de escritorio se recreó; un `af` idéntico no corta el audio.
        if (_platform == EffectsPlatform.windows) _applyEqualizer();
      }
    }));
    _load();
  }

  bool get stabilizeEnabled => _stabilizeEnabled;
  bool get isLoaded => _loaded;
  bool get equalizerEnabled => _eqEnabled;
  EqualizerPreset get equalizerPreset => _eqPreset;
  List<double> get equalizerGains => _eqGains;

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
    _eqEnabled = prefs.getBool(_eqEnabledKey) ?? false;
    _eqGains = decodeEqualizerGains(prefs.getString(_eqGainsKey));
    _eqPreset = parseEqualizerPreset(prefs.getString(_eqPresetKey)) ?? equalizerPresetFor(_eqGains);
    if (_eqPreset != EqualizerPreset.personalizado) _eqGains = equalizerPresetGains(_eqPreset);
    _loaded = true;
    notifyListeners();
    _lastEqFlush = _clock.elapsed;
    unawaited(_applyEqualizer());
    await _apply();
  }

  Future<void> setStabilizeEnabled(bool enabled) async {
    _stabilizeEnabled = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_stabilizeKey, enabled);
    await _apply();
  }

  Future<void> setEqualizerEnabled(bool enabled) {
    _eqEnabled = enabled;
    return _equalizerChanged(immediate: true);
  }

  Future<void> selectEqualizerPreset(EqualizerPreset preset) {
    _eqPreset = preset;
    if (preset != EqualizerPreset.personalizado) _eqGains = equalizerPresetGains(preset);
    return _equalizerChanged(immediate: true);
  }

  /// Pensado para un slider: aplica como mucho cada [_eqThrottle] y el último
  /// valor siempre llega.
  Future<void> setEqualizerBand(int index, double db) {
    if (index < 0 || index >= _eqGains.length) return Future.value();
    final gains = List<double>.of(_eqGains);
    gains[index] = normalizeEqualizerGain(db);
    _eqGains = List<double>.unmodifiable(gains);
    _eqPreset = EqualizerPreset.personalizado;
    return _equalizerChanged(immediate: false);
  }

  Future<void> resetEqualizer() => selectEqualizerPreset(EqualizerPreset.plano);

  Future<void> _equalizerChanged({required bool immediate}) {
    notifyListeners();
    if (immediate) return _flushEqualizer();
    if (_eqTimer != null) return Future.value();
    final last = _lastEqFlush;
    final since = last == null ? _eqThrottle : _clock.elapsed - last;
    if (since >= _eqThrottle) return _flushEqualizer();
    _eqTimer = Timer(_eqThrottle - since, _flushEqualizer);
    return Future.value();
  }

  Future<void> _flushEqualizer() async {
    _eqTimer?.cancel();
    _eqTimer = null;
    if (_disposed) return;
    _lastEqFlush = _clock.elapsed;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_eqEnabledKey, _eqEnabled);
    await prefs.setString(_eqPresetKey, _eqPreset.name);
    await prefs.setString(_eqGainsKey, encodeEqualizerGains(_eqGains));
    await _applyEqualizer();
  }

  /// Un envío a la vez: si llega otro cambio mientras uno está en vuelo, al
  /// terminar se reenvía el estado actual, así uno viejo nunca pisa a uno nuevo.
  Future<void> _applyEqualizer() async {
    if (_eqApplying) {
      _eqDirty = true;
      return;
    }
    _eqApplying = true;
    try {
      do {
        _eqDirty = false;
        if (_disposed) return;
        switch (_platform) {
          case EffectsPlatform.android:
            await _equalizer.configure(buildAndroidEqualizerArgs(enabled: _eqEnabled, gains: _eqGains));
          case EffectsPlatform.windows:
            await _applyEqualizerWindows();
          case EffectsPlatform.other:
            break;
        }
      } while (_eqDirty);
    } finally {
      _eqApplying = false;
    }
  }

  Future<void> _applyEqualizerWindows() async {
    final props = buildWindowsEqualizerProperties(enabled: _eqEnabled, gains: _eqGains);
    for (var attempt = 0;; attempt++) {
      if (_disposed || _eqDirty) return;
      if (await _setMpv(props)) return;
      if (attempt >= _retryDelays.length) {
        appLog('AudioEffects: el reproductor de escritorio aún no está listo, no se aplicó el ecualizador');
        return;
      }
      await Future<void>.delayed(_retryDelays[attempt]);
    }
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
    _eqTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    if (_platform == EffectsPlatform.android) _leveler.disable();
    super.dispose();
  }
}
