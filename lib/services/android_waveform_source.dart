import 'package:flutter/services.dart';

import 'waveform_source.dart';

/// Extractor nativo de Android (`MediaExtractor` + `MediaCodec`), que
/// acepta URIs `content://`.
class AndroidWaveformSource implements WaveformSource {
  static const MethodChannel _channel = MethodChannel('heardy/waveform');

  final int samples;

  AndroidWaveformSource({this.samples = 800});

  @override
  Future<List<double>?> extract(String uri) async {
    try {
      final result = await _channel.invokeMethod<List<dynamic>>('extract', {
        'uri': uri,
        'samples': samples,
      });
      return result?.map((e) => (e as num).toDouble()).toList();
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
