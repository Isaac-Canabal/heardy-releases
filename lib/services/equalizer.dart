import 'dart:math' as math;

/// Bandas del ecualizador (Hz). Deben coincidir con el procesador de Android
/// (`HeardyEqualizer.BAND_FREQUENCIES_HZ`) y con la cadena de mpv.
const equalizerBandsHz = <int>[31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
const double equalizerMinDb = -12;
const double equalizerMaxDb = 12;
const double equalizerStepDb = 0.5;
const double equalizerQ = 1.41;

final List<double> flatEqualizerGains = List<double>.unmodifiable(List<double>.filled(equalizerBandsHz.length, 0));

enum EqualizerPreset { plano, graves, voces, rock, pop, electronica, acustico, clasica, hipHop, agudos, personalizado }

const _presetGains = <EqualizerPreset, List<double>>{
  EqualizerPreset.plano: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  EqualizerPreset.graves: [6, 5.5, 4.5, 3, 1, 0, 0, 0, 0, 0],
  EqualizerPreset.voces: [-3, -2.5, -2, -1, 1, 3, 4, 3.5, 2, 0],
  EqualizerPreset.rock: [5, 4, 3, 1, -1, -1.5, 0, 2, 3.5, 4.5],
  EqualizerPreset.pop: [-1, 0, 1.5, 3, 4, 3, 1.5, 0, -0.5, -1],
  EqualizerPreset.electronica: [5.5, 5, 3, 0, -1.5, 0, 1, 2.5, 4, 4.5],
  EqualizerPreset.acustico: [3, 3, 2.5, 1, 1.5, 1.5, 2.5, 3, 2.5, 1.5],
  EqualizerPreset.clasica: [3, 2.5, 1.5, 0.5, 0, 0, 0, 1, 2, 3],
  EqualizerPreset.hipHop: [5.5, 5, 3, 1.5, -1, -1, 1, 0, 1.5, 2.5],
  EqualizerPreset.agudos: [0, 0, 0, 0, 0, 0.5, 2, 4, 5.5, 6],
};

/// Ganancias de un preset. `personalizado` no tiene curva propia: devuelve plano.
List<double> equalizerPresetGains(EqualizerPreset preset) =>
    List<double>.unmodifiable(_presetGains[preset] ?? flatEqualizerGains);

/// El preset cuya curva coincide exactamente, o `personalizado`.
EqualizerPreset equalizerPresetFor(List<double> gains) {
  for (final entry in _presetGains.entries) {
    if (_sameGains(entry.value, gains)) return entry.key;
  }
  return EqualizerPreset.personalizado;
}

EqualizerPreset? parseEqualizerPreset(String? name) {
  for (final preset in EqualizerPreset.values) {
    if (preset.name == name) return preset;
  }
  return null;
}

bool _sameGains(List<double> a, List<double> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Acota a ±12 dB y redondea al paso de 0.5 (nunca -0.0 ni un no finito).
double normalizeEqualizerGain(double db) {
  if (!db.isFinite) return 0;
  final clamped = db.clamp(equalizerMinDb, equalizerMaxDb).toDouble();
  return (clamped / equalizerStepDb).round() * equalizerStepDb;
}

List<double> _normalized(List<double> gains) =>
    List<double>.generate(equalizerBandsHz.length, (i) => i < gains.length ? normalizeEqualizerGain(gains[i]) : 0);

/// Preamp (dB, <= 0) que compensa la mayor subida para que no recorte.
double equalizerPreampDb(List<double> gains) {
  final maxBoost = gains.fold<double>(0, (m, g) => g.isFinite ? math.max(m, g) : m);
  return maxBoost <= 0 ? 0 : -maxBoost;
}

String _formatDb(double db) {
  final v = (db * 10).round() / 10;
  if (v == 0) return '0';
  return v == v.truncateToDouble() ? v.toInt().toString() : v.toString();
}

/// Cadena `af` de mpv. El libmpv empaquetado no trae `aresample`, así que el
/// `format=floatp` inicial es obligatorio; un `af` inválido deja mpv mudo.
String buildMpvEqualizerFilter(List<double> gains) {
  final g = _normalized(gains);
  final bands = [
    for (var i = 0; i < equalizerBandsHz.length; i++)
      '@eq$i:lavfi=[equalizer=f=${equalizerBandsHz[i]}:t=q:w=$equalizerQ:g=${_formatDb(g[i])}]',
  ];
  return 'format=format=floatp,${bands.join(',')}';
}

/// Propiedades de mpv del ecualizador. El preamp va en `volume-gain` porque
/// no hay filtro `volume` en el build; no toca `replaygain-*` (nivelador).
Map<String, String> buildWindowsEqualizerProperties({required bool enabled, required List<double> gains}) {
  if (!enabled) return const {'af': '', 'volume-gain': '0'};
  return {
    'af': buildMpvEqualizerFilter(gains),
    'volume-gain': _formatDb(equalizerPreampDb(_normalized(gains))),
  };
}

/// Argumentos de `configure` en el canal `heardy/equalizer`.
Map<String, Object> buildAndroidEqualizerArgs({required bool enabled, required List<double> gains}) {
  final g = _normalized(gains);
  return {
    'enabled': enabled,
    'preampDb': enabled ? equalizerPreampDb(g) : 0.0,
    'gainsDb': g,
  };
}

String encodeEqualizerGains(List<double> gains) => _normalized(gains).map(_formatDb).join(',');

/// Lo guardado, o plano si falta, está roto o no tiene 10 valores.
List<double> decodeEqualizerGains(String? stored) {
  if (stored == null || stored.isEmpty) return flatEqualizerGains;
  final parts = stored.split(',');
  if (parts.length != equalizerBandsHz.length) return flatEqualizerGains;
  final values = <double>[];
  for (final p in parts) {
    final v = double.tryParse(p.trim());
    if (v == null || !v.isFinite) return flatEqualizerGains;
    values.add(normalizeEqualizerGain(v));
  }
  return List<double>.unmodifiable(values);
}
