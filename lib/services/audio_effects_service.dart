import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_player_handler.dart';

/// Bandas fijas para el ecualizador de escritorio (mpv no expone bandas
/// "reales" de hardware como sí hace `AndroidEqualizer.parameters` en
/// Android — ver [EqualizerPreset] para por qué cada plataforma calcula sus
/// ganancias por separado a partir de la misma curva en vez de compartir un
/// array de ganancias con índices fijos).
const List<double> windowsEqBands = [60, 230, 910, 3600, 14000];

enum EqualizerPreset { flat, vocalBoost, trebleFocus }

/// Curvas de ganancia (Hz -> dB) por preset, en puntos de control sobre eje
/// de frecuencia logarítmico. `gainForFrequency` interpola entre ellos, así
/// que sirve tanto para las 5 bandas fijas de escritorio como para las
/// bandas reales (variables según el dispositivo) que reporta
/// `AndroidEqualizer.parameters` en Android — un solo lugar donde vive cada
/// preset, sin duplicar valores por plataforma.
const Map<EqualizerPreset, List<MapEntry<double, double>>> _presetCurves = {
  EqualizerPreset.flat: [MapEntry(20, 0), MapEntry(20000, 0)],
  EqualizerPreset.vocalBoost: [
    MapEntry(60, -2),
    MapEntry(230, 0),
    MapEntry(910, 4),
    MapEntry(3600, 3),
    MapEntry(14000, -1),
  ],
  EqualizerPreset.trebleFocus: [
    MapEntry(60, -3),
    MapEntry(230, -2),
    MapEntry(910, 0),
    MapEntry(3600, 3),
    MapEntry(14000, 6),
  ],
};

/// Interpola la ganancia (dB) de un preset para una frecuencia arbitraria,
/// en eje logarítmico (así una banda a mitad de camino entre 230 Hz y 910 Hz
/// no queda a mitad de camino lineal, que sonaría desplazada hacia agudos).
/// Función pura y de nivel superior a propósito, para poder testearla sin
/// un dispositivo real ni `just_audio`/`media_kit`.
double gainForFrequency(List<MapEntry<double, double>> curve, double frequencyHz) {
  if (curve.isEmpty) return 0;
  if (frequencyHz <= curve.first.key) return curve.first.value;
  if (frequencyHz >= curve.last.key) return curve.last.value;
  for (var i = 0; i < curve.length - 1; i++) {
    final a = curve[i];
    final b = curve[i + 1];
    if (frequencyHz >= a.key && frequencyHz <= b.key) {
      final logA = math.log(a.key);
      final logB = math.log(b.key);
      final t = (math.log(frequencyHz) - logA) / (logB - logA);
      return a.value + (b.value - a.value) * t;
    }
  }
  return curve.last.value;
}

List<double> gainsForPreset(EqualizerPreset preset, List<double> bandFrequencies) {
  final curve = _presetCurves[preset]!;
  return bandFrequencies.map((f) => gainForFrequency(curve, f)).toList();
}

/// Construye la cadena de filtros `af` de mpv para el backend de escritorio.
/// Función pura (sin `NativePlayer`, sin `Platform.isWindows`) para poder
/// testearla igual que [gainForFrequency]. `dynaudnorm` es el filtro de
/// libavfilter que hace de "estabilizar audio"; cada banda del ecualizador es
/// un `equalizer=` encadenado con coma. `null` significa "sin filtros",
/// que en mpv se aplica seteando la propiedad `af` a cadena vacía.
String? buildWindowsAudioFilter({
  required bool stabilizeEnabled,
  required bool equalizerEnabled,
  required List<double> gains,
}) {
  final filters = <String>[];
  if (stabilizeEnabled) filters.add('dynaudnorm');
  if (equalizerEnabled) {
    for (var i = 0; i < windowsEqBands.length && i < gains.length; i++) {
      final gain = gains[i];
      if (gain == 0) continue;
      final f = windowsEqBands[i].round();
      filters.add('equalizer=f=$f:width_type=h:width=$f:g=${gain.toStringAsFixed(1)}');
    }
  }
  if (filters.isEmpty) return null;
  return filters.join(',');
}

/// Ajustes de audio (estabilizar volumen + ecualizador), aplicados en Android
/// vía los efectos oficiales de `just_audio` (ver [AudioPlayerHandler]) y en
/// escritorio vía la propiedad `af` de mpv (ver [buildWindowsAudioFilter]),
/// porque son dos mecanismos sin superficie común. `AudioPlayerHandler` se
/// inyecta (ya es un `Provider` en `main.dart`) en vez de construirse acá,
/// siguiendo la regla de inyección de dependencias del repo.
class AudioEffectsService with ChangeNotifier {
  static const _stabilizeKey = 'audio_fx_stabilize_enabled';
  static const _equalizerKey = 'audio_fx_equalizer_enabled';
  static const _presetKey = 'audio_fx_preset';

  final AudioPlayerHandler _audioHandler;

  bool _stabilizeEnabled = false;
  bool _equalizerEnabled = false;
  EqualizerPreset _preset = EqualizerPreset.flat;
  bool _loaded = false;

  AudioEffectsService(this._audioHandler) {
    _load();
  }

  bool get stabilizeEnabled => _stabilizeEnabled;
  bool get equalizerEnabled => _equalizerEnabled;
  EqualizerPreset get preset => _preset;
  bool get isLoaded => _loaded;

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _stabilizeEnabled = prefs.getBool(_stabilizeKey) ?? false;
    _equalizerEnabled = prefs.getBool(_equalizerKey) ?? false;
    final presetIndex = prefs.getInt(_presetKey);
    if (presetIndex != null && presetIndex >= 0 && presetIndex < EqualizerPreset.values.length) {
      _preset = EqualizerPreset.values[presetIndex];
    }
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

  Future<void> setEqualizerEnabled(bool enabled) async {
    _equalizerEnabled = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_equalizerKey, enabled);
    await _apply();
  }

  Future<void> setPreset(EqualizerPreset preset) async {
    _preset = preset;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_presetKey, preset.index);
    await _apply();
  }

  Future<void> _apply() async {
    if (Platform.isAndroid) {
      await _applyAndroid();
    } else if (Platform.isWindows) {
      await _applyWindows();
    }
  }

  Future<void> _applyAndroid() async {
    final loudness = _audioHandler.androidLoudnessEnhancer;
    await loudness.setEnabled(_stabilizeEnabled);
    if (_stabilizeEnabled) await loudness.setTargetGain(0);

    final equalizer = _audioHandler.androidEqualizer;
    await equalizer.setEnabled(_equalizerEnabled);
    if (_equalizerEnabled) {
      // `parameters` sólo se resuelve una vez que el efecto está activo (ver
      // AndroidEqualizer._activate en just_audio) — recién ahí existen las
      // bandas reales del dispositivo.
      final params = await equalizer.parameters;
      final frequencies = params.bands.map((b) => b.centerFrequency).toList();
      final gains = gainsForPreset(_preset, frequencies);
      for (var i = 0; i < params.bands.length; i++) {
        await params.bands[i].setGain(gains[i]);
      }
    }
  }

  Future<void> _applyWindows() async {
    final rawPlayer = JustAudioMediaKit.rawPlayer;
    final platform = rawPlayer?.platform;
    if (platform is! NativePlayer) return;
    final gains = _equalizerEnabled ? gainsForPreset(_preset, windowsEqBands) : const <double>[];
    final filter = buildWindowsAudioFilter(
      stabilizeEnabled: _stabilizeEnabled,
      equalizerEnabled: _equalizerEnabled,
      gains: gains,
    );
    await platform.setProperty('af', filter ?? '');
  }
}
