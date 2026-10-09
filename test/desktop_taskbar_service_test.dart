// Cubre el servicio de la barra de tareas de Windows (botones de miniatura +
// teclas multimedia globales) contra un canal y un reproductor falsos. La parte
// nativa (windows/runner/taskbar_media.cpp) sólo se puede verificar a mano.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heardy/services/desktop_taskbar_service.dart';

class _FakePlayback implements TaskbarPlayback {
  final controller = StreamController<bool>.broadcast();
  bool playing = false;
  final calls = <String>[];

  @override
  Stream<bool> get playingStream => controller.stream;
  @override
  bool get isPlaying => playing;
  @override
  Future<void> play() async => calls.add('play');
  @override
  Future<void> pause() async => calls.add('pause');
  @override
  Future<void> skipToNext() async => calls.add('next');
  @override
  Future<void> skipToPrevious() async => calls.add('previous');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('heardy/taskbar');
  late _FakePlayback playback;
  late List<MethodCall> sent;
  late Object? initResult;

  setUp(() {
    playback = _FakePlayback();
    sent = [];
    initResult = {'hotkeysRegistered': true};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      sent.add(call);
      return call.method == 'init' ? initResult : null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> nativeAction(String action) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(MethodCall('onAction', action)),
      (_) {},
    );
  }

  DesktopTaskbarService build({bool windows = true}) =>
      DesktopTaskbarService(playback: playback, channel: channel, isWindows: windows);

  test('thumbnailSpecFor: reproduciendo muestra pausa, si no, reproducir', () {
    expect(thumbnailSpecFor(true).icon, 'pause');
    expect(thumbnailSpecFor(true).tooltip, 'Pausar');
    expect(thumbnailSpecFor(false).icon, 'play');
    expect(thumbnailSpecFor(false).tooltip, 'Reproducir');
  });

  test('shouldHandleMediaKeyInApp: sólo si las teclas globales no están', () {
    expect(shouldHandleMediaKeyInApp(true), isFalse);
    expect(shouldHandleMediaKeyInApp(false), isTrue);
  });

  test('init manda los tooltips y recuerda hotkeysRegistered', () async {
    final s = build();
    await s.init();
    expect(sent.first.method, 'init');
    final args = Map<String, dynamic>.from(sent.first.arguments as Map);
    expect(args['previous'], 'Anterior');
    expect(args['next'], 'Siguiente');
    expect(args['play'], 'Reproducir');
    expect(args['pause'], 'Pausar');
    expect(s.nativeHotkeysActive, isTrue);
    await s.dispose();
  });

  test('si el registro de teclas falla, la app las maneja en primer plano',
      () async {
    initResult = {'hotkeysRegistered': false};
    final s = build();
    await s.init();
    expect(s.nativeHotkeysActive, isFalse);
    expect(shouldHandleMediaKeyInApp(s.nativeHotkeysActive), isTrue);
    await s.dispose();
  });

  test('playing se reenvía como setPlaying sin repetir valores', () async {
    final s = build();
    await s.init();
    sent.clear();
    playback.controller.add(true);
    playback.controller.add(true);
    playback.controller.add(false);
    await Future<void>.delayed(Duration.zero);
    final plays = sent.where((c) => c.method == 'setPlaying').toList();
    expect(plays.map((c) => c.arguments), [true, false]);
    await s.dispose();
  });

  test('onAction previous/next llaman al reproductor', () async {
    final s = build();
    await s.init();
    await nativeAction('previous');
    await nativeAction('next');
    expect(playback.calls, ['previous', 'next']);
    await s.dispose();
  });

  test('playPause lee el estado en el momento del clic', () async {
    final s = build();
    await s.init();
    playback.playing = false;
    await nativeAction('playPause');
    playback.playing = true;
    await nativeAction('playPause');
    expect(playback.calls, ['play', 'pause']);
    await s.dispose();
  });

  test('dispose avisa al lado nativo y deja de escuchar', () async {
    final s = build();
    await s.init();
    await s.dispose();
    sent.clear();
    playback.controller.add(true);
    await Future<void>.delayed(Duration.zero);
    expect(sent, isEmpty);
    await s.dispose();
    expect(sent, isEmpty);
  });

  test('fuera de Windows no hace nada', () async {
    final s = build(windows: false);
    await s.init();
    expect(sent, isEmpty);
    expect(s.nativeHotkeysActive, isFalse);
    await s.dispose();
    expect(sent, isEmpty);
  });
}
