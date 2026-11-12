// Lo que el editor de transiciones necesita saber de una canción: su análisis
// (tempo, rejilla, tonalidad) y los resúmenes de nivel con los que se dibuja:
// una vista general de baja resolución y el final y el principio con detalle.
// Se guarda en una caché pequeña en almacenamiento privado; nunca se sube.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../mix/mix_analysis.dart' show SongAnalysis;
import '../transition_analysis.dart';

const kTransitionProfileVersion = 1;

/// Segundos del final y del principio de la canción que se resumen con detalle.
const kTransitionDetailWindowSec = 60.0;
const kTransitionOverviewPointsPerSecond = 2;
const kTransitionDetailPointsPerSecond = 20;

class TransitionSongProfile {
  const TransitionSongProfile({
    required this.songId,
    required this.stamp,
    required this.durationSec,
    required this.analysis,
    required this.overview,
    required this.outro,
    required this.outroOffsetSec,
    required this.intro,
  });

  final String songId;

  /// Huella del archivo con que se calculó (hash o tamaño): si cambia, se recalcula.
  final String stamp;
  final double durationSec;
  final SongAnalysis analysis;

  /// Toda la canción a baja resolución.
  final TransitionWaveform overview;

  /// Últimos segundos de la canción, que empiezan en [outroOffsetSec].
  final TransitionWaveform outro;
  final double outroOffsetSec;

  /// Primeros segundos de la canción.
  final TransitionWaveform intro;

  Map<String, dynamic> toJson() => {
        'v': kTransitionProfileVersion,
        'songId': songId,
        'stamp': stamp,
        'durationSec': durationSec,
        'analysis': analysis.toJson(),
        'overview': waveformToJson(overview),
        'outro': waveformToJson(outro),
        'outroOffsetSec': outroOffsetSec,
        'intro': waveformToJson(intro),
      };

  static TransitionSongProfile fromJson(Map<String, dynamic> j) {
    if (j['v'] != kTransitionProfileVersion) throw const FormatException('versión de perfil desconocida');
    return TransitionSongProfile(
      songId: j['songId'] as String,
      stamp: j['stamp'] as String,
      durationSec: (j['durationSec'] as num).toDouble(),
      analysis: SongAnalysis.fromJson(j['analysis'] as Map<String, dynamic>),
      overview: waveformFromJson(j['overview'] as Map<String, dynamic>),
      outro: waveformFromJson(j['outro'] as Map<String, dynamic>),
      outroOffsetSec: (j['outroOffsetSec'] as num).toDouble(),
      intro: waveformFromJson(j['intro'] as Map<String, dynamic>),
    );
  }
}

Map<String, dynamic> waveformToJson(TransitionWaveform w) => {
      'pps': w.pointsPerSecond,
      'durationSec': w.durationSec,
      'rms': w.rmsDb,
      'peak': w.peakDb,
      'low': w.lowDb,
      'mid': w.midDb,
      'high': w.highDb,
    };

TransitionWaveform waveformFromJson(Map<String, dynamic> j) {
  List<double> list(String k) => [for (final v in j[k] as List) (v as num).toDouble()];
  return TransitionWaveform(
    pointsPerSecond: j['pps'] as int,
    durationSec: (j['durationSec'] as num).toDouble(),
    rmsDb: list('rms'),
    peakDb: list('peak'),
    lowDb: list('low'),
    midDb: list('mid'),
    highDb: list('high'),
  );
}

class TransitionProfileCache {
  TransitionProfileCache(this.rootPath, {this.maxEntries = 400});
  final String rootPath;
  final int maxEntries;

  String _path(String songId) {
    final key = sha256.convert(utf8.encode(songId)).toString().substring(0, 24);
    return '$rootPath${Platform.pathSeparator}$key.json';
  }

  /// Perfil guardado, o `null` si no hay, está dañado o su [stamp] ya no coincide.
  Future<TransitionSongProfile?> lookup(String songId, String stamp) async {
    final f = File(_path(songId));
    try {
      if (!await f.exists()) return null;
      final p = TransitionSongProfile.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
      if (p.songId != songId || p.stamp != stamp) return null;
      await f.setLastModified(DateTime.now());
      return p;
    } catch (e) {
      print('Transición: perfil en caché ilegible, se recalcula (${e.runtimeType})');
      return null;
    }
  }

  Future<void> save(TransitionSongProfile p) async {
    try {
      await Directory(rootPath).create(recursive: true);
      final tmp = File('${_path(p.songId)}.tmp');
      await tmp.writeAsString(jsonEncode(p.toJson()));
      await tmp.rename(_path(p.songId));
      await _trim();
    } catch (e) {
      print('Transición: no se pudo guardar el perfil (${e.runtimeType})');
    }
  }

  Future<void> remove(String songId) async {
    final f = File(_path(songId));
    if (await f.exists()) await f.delete();
  }

  Future<void> _trim() async {
    final files = Directory(rootPath).listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList();
    if (files.length <= maxEntries) return;
    files.sort((a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()));
    for (final f in files.take(files.length - maxEntries)) {
      try {
        f.deleteSync();
      } catch (_) {}
    }
  }
}
