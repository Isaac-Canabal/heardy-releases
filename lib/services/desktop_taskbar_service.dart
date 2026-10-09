import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'audio_player_handler.dart';

/// Lo mínimo que el servicio necesita del reproductor; permite probarlo con un
/// doble sin `just_audio`.
abstract class TaskbarPlayback {
  Stream<bool> get playingStream;
  bool get isPlaying;
  Future<void> play();
  Future<void> pause();
  Future<void> skipToNext();
  Future<void> skipToPrevious();
}

class HandlerTaskbarPlayback implements TaskbarPlayback {
  final AudioPlayerHandler _handler;
  HandlerTaskbarPlayback(this._handler);

  @override
  Stream<bool> get playingStream => _handler.playbackState.map((s) => s.playing);
  @override
  bool get isPlaying => _handler.playbackState.value.playing;
  @override
  Future<void> play() => _handler.play();
  @override
  Future<void> pause() => _handler.pause();
  @override
  Future<void> skipToNext() => _handler.skipToNext();
  @override
  Future<void> skipToPrevious() => _handler.skipToPrevious();
}

class ThumbnailSpec {
  final String icon; // 'play' | 'pause'
  final String tooltip;
  const ThumbnailSpec(this.icon, this.tooltip);
}

/// Icono y tooltip del botón central según el estado.
ThumbnailSpec thumbnailSpecFor(bool playing) =>
    playing ? const ThumbnailSpec('pause', 'Pausar') : const ThumbnailSpec('play', 'Reproducir');

/// Con las teclas multimedia globales nativas registradas, la app no debe
/// atenderlas también en primer plano (una pulsación haría dos acciones).
bool shouldHandleMediaKeyInApp(bool nativeHotkeysActive) => !nativeHotkeysActive;

/// Botones de miniatura de la barra de tareas y teclas multimedia globales de
/// Windows (windows/runner/taskbar_media.cpp), por el canal `heardy/taskbar`.
class DesktopTaskbarService {
  final TaskbarPlayback _playback;
  final MethodChannel _channel;
  final bool _enabled;
  StreamSubscription<bool>? _sub;
  bool _hotkeysActive = false;
  bool _initialized = false;

  DesktopTaskbarService({
    required TaskbarPlayback playback,
    MethodChannel? channel,
    bool? isWindows,
  })  : _playback = playback,
        _channel = channel ?? const MethodChannel('heardy/taskbar'),
        _enabled = isWindows ?? Platform.isWindows;

  bool get nativeHotkeysActive => _hotkeysActive;

  Future<void> init() async {
    if (!_enabled || _initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler(_onCall);
    try {
      final res = await _channel.invokeMethod<Object?>('init', {
        'previous': 'Anterior',
        'next': 'Siguiente',
        'play': thumbnailSpecFor(false).tooltip,
        'pause': thumbnailSpecFor(true).tooltip,
      });
      _hotkeysActive = res is Map && res['hotkeysRegistered'] == true;
    } catch (e) {
      debugPrint('Barra de tareas: init falló ($e)');
      _hotkeysActive = false;
    }
    _sub = _playback.playingStream.distinct().listen((playing) {
      _channel.invokeMethod<void>('setPlaying', playing).catchError((Object e) {
        debugPrint('Barra de tareas: setPlaying falló ($e)');
      });
    });
  }

  Future<Object?> _onCall(MethodCall call) async {
    if (call.method != 'onAction') return null;
    switch (call.arguments) {
      case 'previous':
        await _playback.skipToPrevious();
      case 'next':
        await _playback.skipToNext();
      case 'playPause':
        // Se lee al momento del clic: el icono de la miniatura puede ir atrasado.
        await (_playback.isPlaying ? _playback.pause() : _playback.play());
    }
    return null;
  }

  Future<void> dispose() async {
    if (!_enabled || !_initialized) return;
    _initialized = false;
    _hotkeysActive = false;
    await _sub?.cancel();
    _sub = null;
    _channel.setMethodCallHandler(null);
    try {
      await _channel.invokeMethod<void>('dispose');
    } catch (_) {}
  }
}
