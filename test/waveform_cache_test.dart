import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:heardy/services/waveform_cache.dart';
import 'package:heardy/services/waveform_logic.dart';
import 'package:heardy/services/waveform_source.dart';

class _FakeSource implements WaveformSource {
  int calls = 0;
  List<double>? result;
  _FakeSource(this.result);

  @override
  Future<List<double>?> extract(String uri) async {
    calls++;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return result;
  }
}

void main() {
  late Directory dir;
  late WaveformCache cache;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('heardy_wave_');
    cache = WaveformCache(() async => dir);
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('escribe y lee', () async {
    final peaks = Uint8List.fromList([1, 2, 3]);
    await cache.write('abc', peaks);
    expect(await cache.read('abc'), peaks);
    expect(await cache.read('otro'), isNull);
  });

  test('archivo corrupto se trata como ausente', () async {
    File('${dir.path}/abc.wave').writeAsBytesSync([1, 2, 3]);
    expect(await cache.read('abc'), isNull);
  });

  test('el id se sanea para el nombre de archivo', () {
    expect(WaveformCache.fileNameFor('a/b:c'), 'a_b_c.wave');
  });

  test('repositorio extrae una vez y luego usa la caché', () async {
    final source = _FakeSource(List.generate(1000, (i) => (i % 10) / 10));
    final repo = WaveformRepository(source: source, cache: cache);
    final first = await repo.load('s1', 'content://x');
    expect(first, isNotNull);
    expect(first!.length, kWaveformBars);
    final second = await repo.load('s1', 'content://x');
    expect(second, first);
    expect(source.calls, 1);
  });

  test('llamadas simultáneas comparten una sola extracción', () async {
    final source = _FakeSource([0.1, 0.9]);
    final repo = WaveformRepository(source: source, cache: cache);
    await Future.wait([repo.load('s2', 'u'), repo.load('s2', 'u')]);
    expect(source.calls, 1);
  });

  test('si el extractor falla devuelve null y no guarda nada', () async {
    final repo = WaveformRepository(source: _FakeSource(null), cache: cache);
    expect(await repo.load('s3', 'u'), isNull);
    expect(await cache.read('s3'), isNull);
  });
}
