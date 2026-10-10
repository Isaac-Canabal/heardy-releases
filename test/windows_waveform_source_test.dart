import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:heardy/services/windows_waveform_source.dart';

Uint8List pcm(List<int> samples) {
  final b = ByteData(samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    b.setInt16(i * 2, samples[i], Endian.little);
  }
  return b.buffer.asUint8List();
}

class _FakeProcess implements WaveformProcess {
  _FakeProcess(this._chunks, this._exit, {this.hang = false});
  final List<List<int>> _chunks;
  final int _exit;
  final bool hang;
  bool killed = false;
  final _done = Completer<int>();

  @override
  Stream<List<int>> get stdout async* {
    for (final c in _chunks) {
      yield c;
    }
    if (hang) await _done.future;
  }

  @override
  Future<int> get exitCode => hang ? _done.future : Future.value(_exit);

  @override
  void kill() {
    killed = true;
    if (!_done.isCompleted) _done.complete(-1);
  }
}

void main() {
  group('pcmS16leToRms', () {
    test('silencio da ventanas en cero', () async {
      final r = await pcmS16leToRms(
          Stream.value(pcm(List.filled(1600, 0))), windowSamples: 800);
      expect(r, [0.0, 0.0]);
    });

    test('escala completa da RMS 32767/32768 aprox 1', () async {
      final r = await pcmS16leToRms(
          Stream.value(pcm(List.filled(800, 32767))), windowSamples: 800);
      expect(r!.single, closeTo(32767, 0.01));
    });

    test('cuenta una ventana parcial final', () async {
      final r = await pcmS16leToRms(
          Stream.value(pcm(List.filled(1000, 100))), windowSamples: 800);
      expect(r!.length, 2);
      expect(r[1], closeTo(100, 1e-9));
    });

    test('chunks partidos en cualquier byte dan lo mismo que uno solo', () async {
      final samples = List<int>.generate(2000, (i) => (i * 37 % 2000) - 1000);
      final whole = await pcmS16leToRms(Stream.value(pcm(samples)), windowSamples: 800);
      final bytes = pcm(samples);
      final pieces = <List<int>>[];
      for (var i = 0; i < bytes.length; i += 7) {
        pieces.add(bytes.sublist(i, i + 7 > bytes.length ? bytes.length : i + 7));
      }
      final split = await pcmS16leToRms(Stream.fromIterable(pieces), windowSamples: 800);
      expect(split, whole);
    });

    test('un byte suelto al final se descarta', () async {
      final bytes = [...pcm(List.filled(800, 50)), 0x7f];
      final r = await pcmS16leToRms(Stream.value(bytes), windowSamples: 800);
      expect(r!.length, 1);
    });

    test('vacio da lista vacia', () async {
      expect(await pcmS16leToRms(const Stream<List<int>>.empty()), isEmpty);
    });

    test('supera el limite de muestras -> null', () async {
      final r = await pcmS16leToRms(
          Stream.value(pcm(List.filled(1000, 1))),
          windowSamples: 100, maxSamples: 500);
      expect(r, isNull);
    });
  });

  group('WindowsWaveformSource', () {
    test('sin binario -> null', () async {
      final s = WindowsWaveformSource(
        locator: () => null,
        starter: (_, __) async => fail('no debe ejecutar'),
      );
      expect(await s.extract('a.m4a'), isNull);
    });

    test('codigo de salida != 0 -> null', () async {
      final s = WindowsWaveformSource(
        locator: () => 'ffmpeg.exe',
        starter: (_, __) async => _FakeProcess([pcm(List.filled(800, 5))], 1),
      );
      expect(await s.extract('a.m4a'), isNull);
    });

    test('salida vacia -> null', () async {
      final s = WindowsWaveformSource(
        locator: () => 'ffmpeg.exe',
        starter: (_, __) async => _FakeProcess([], 0),
      );
      expect(await s.extract('a.m4a'), isNull);
    });

    test('exito -> lista y argumentos esperados', () async {
      List<String>? args;
      final s = WindowsWaveformSource(
        locator: () => 'ffmpeg.exe',
        starter: (exe, a) async {
          args = a;
          return _FakeProcess([pcm(List.filled(1600, 100))], 0);
        },
      );
      final r = await s.extract(r'C:\m\a.m4a');
      expect(r, hasLength(2));
      expect(args, containsAllInOrder(['-i', r'C:\m\a.m4a', '-ac', '1', '-ar', '8000', '-f', 's16le']));
      expect(args!.last, '-');
    });

    test('timeout mata el proceso y da null', () async {
      final p = _FakeProcess([], 0, hang: true);
      final s = WindowsWaveformSource(
        locator: () => 'ffmpeg.exe',
        starter: (_, __) async => p,
        timeout: const Duration(milliseconds: 50),
      );
      expect(await s.extract('a.m4a'), isNull);
      expect(p.killed, isTrue);
    });

    test('el starter lanza -> null', () async {
      final s = WindowsWaveformSource(
        locator: () => 'ffmpeg.exe',
        starter: (_, __) async => throw StateError('x'),
      );
      expect(await s.extract('a.m4a'), isNull);
    });
  });
}
