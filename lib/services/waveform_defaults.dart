import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'android_waveform_source.dart';
import 'waveform_cache.dart';
import 'waveform_source.dart';
import 'windows_waveform_source.dart';

WaveformRepository? _defaultRepository;

/// `null` en plataformas sin extractor: ahí se queda el Slider.
WaveformRepository? defaultWaveformRepository() {
  final WaveformSource source;
  if (Platform.isAndroid) {
    source = AndroidWaveformSource();
  } else if (Platform.isWindows) {
    source = WindowsWaveformSource();
  } else {
    return null;
  }
  return _defaultRepository ??= WaveformRepository(
    source: source,
    cache: WaveformCache(() async {
      final base = await getApplicationSupportDirectory();
      return Directory('${base.path}${Platform.pathSeparator}waveforms');
    }),
  );
}
