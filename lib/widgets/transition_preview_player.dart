// Escuchar el clip de una transición sin salir del editor. Es la misma costura
// que usa el editor del Mixer (un archivo efímero en el reproductor de la app),
// aislada tras una interfaz para que la pantalla se pueda probar sin el
// reproductor real.
import 'dart:async';

import 'package:audio_service/audio_service.dart';

import '../services/audio_player_handler.dart';

/// Estado de la escucha: qué suena, por dónde va y si está sonando.
class TransitionPreviewTick {
  const TransitionPreviewTick({required this.mediaId, required this.position, required this.playing});
  final String? mediaId;
  final Duration position;
  final bool playing;
}

abstract class TransitionPreviewPlayer {
  Stream<TransitionPreviewTick> get ticks;

  /// Reproduce el clip [wavPath] desde el principio; [id] distingue este clip de cualquier otra cosa que suene.
  Future<void> play({required String id, required String wavPath, required String title, Duration? duration});
  Future<void> pause();
  Future<void> resume();
  Future<void> seek(Duration position);

  /// Repite el clip que suena en el propio reproductor; `false` lo deja sin repetición.
  Future<void> setLoop(bool on);
  void dispose();
}

String transitionPreviewMediaId(String clipKey) => 'transition:$clipKey';

MediaItem transitionPreviewItem({required String id, required String title, Duration? duration}) => MediaItem(
      id: id,
      title: title,
      album: 'Heardy',
      duration: duration,
      extras: const {
        'isStream': true,
        'isTransitionPreview': true,
        'filePath': '',
        'artPath': '',
      },
    );

/// [TransitionPreviewPlayer] sobre el reproductor de la app: el clip suena como
/// un archivo efímero ([AudioPlayerHandler.playEphemeralFile]): sin fila en
/// `songs`, sin `play_history` y sin restaurarse al abrir la app.
class HandlerTransitionPreviewPlayer implements TransitionPreviewPlayer {
  HandlerTransitionPreviewPlayer(this._handler) {
    _controller = StreamController<TransitionPreviewTick>.broadcast(onListen: _listen, onCancel: _cancel);
  }

  final AudioPlayerHandler _handler;
  late final StreamController<TransitionPreviewTick> _controller;
  final List<StreamSubscription<Object?>> _subs = [];

  void _emit([Object? _]) {
    if (_controller.isClosed) return;
    final player = _handler.player;
    _controller.add(TransitionPreviewTick(
        mediaId: _handler.mediaItem.value?.id, position: player.position, playing: player.playing));
  }

  void _listen() {
    final player = _handler.player;
    _subs.addAll([
      player.positionStream.listen(_emit),
      player.playingStream.listen(_emit),
      _handler.mediaItem.listen(_emit),
    ]);
  }

  void _cancel() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
  }

  @override
  Stream<TransitionPreviewTick> get ticks => _controller.stream;

  @override
  Future<void> play({required String id, required String wavPath, required String title, Duration? duration}) =>
      _handler.playEphemeralFile(transitionPreviewItem(id: id, title: title, duration: duration), wavPath);

  @override
  Future<void> pause() => _handler.pause();

  @override
  Future<void> resume() => _handler.play();

  @override
  Future<void> seek(Duration position) => _handler.seek(position);

  bool _loopApplied = false;

  @override
  Future<void> setLoop(bool on) async {
    final isPreview = _handler.mediaItem.value?.extras?['isTransitionPreview'] == true;
    if (on) {
      if (!isPreview) return;
      _loopApplied = true;
      await _handler.setRepeatMode(AudioServiceRepeatMode.one);
    } else if (_loopApplied) {
      _loopApplied = false;
      // Si ya suena otra cosa, su repetición no es nuestra.
      if (isPreview) await _handler.setRepeatMode(AudioServiceRepeatMode.none);
    }
  }

  @override
  void dispose() {
    _cancel();
    _controller.close();
  }
}
