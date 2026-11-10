import 'package:audio_service/audio_service.dart';

/// Nombre de la acción personalizada del botón de repetir de la notificación.
const kToggleRepeatAction = 'toggleRepeat';

/// Siguiente modo de repetición al tocar el botón: ninguno, toda la cola, una.
/// Con una cola de streaming (`allowAll` falso) "toda la cola" no existe en el
/// reproductor, así que el ciclo es solo ninguno y una.
AudioServiceRepeatMode nextRepeatMode(AudioServiceRepeatMode current, {bool allowAll = true}) {
  switch (current) {
    case AudioServiceRepeatMode.none:
    case AudioServiceRepeatMode.group:
      return allowAll ? AudioServiceRepeatMode.all : AudioServiceRepeatMode.one;
    case AudioServiceRepeatMode.all:
      return AudioServiceRepeatMode.one;
    case AudioServiceRepeatMode.one:
      return AudioServiceRepeatMode.none;
  }
}

/// Icono (vector monocromo en `res/drawable`) del botón de repetir según el
/// estado actual.
String repeatIconResource(AudioServiceRepeatMode mode) => switch (mode) {
      AudioServiceRepeatMode.one => 'drawable/ic_repeat_one',
      AudioServiceRepeatMode.all => 'drawable/ic_repeat_all',
      _ => 'drawable/ic_repeat_off',
    };

String repeatLabel(AudioServiceRepeatMode mode) => switch (mode) {
      AudioServiceRepeatMode.one => 'Repetir una',
      AudioServiceRepeatMode.all => 'Repetir todo',
      _ => 'Repetir desactivado',
    };

MediaControl repeatControl(AudioServiceRepeatMode mode) => MediaControl.custom(
      androidIcon: repeatIconResource(mode),
      label: repeatLabel(mode),
      name: kToggleRepeatAction,
    );

/// Botones de la notificación y de la pantalla de bloqueo: anterior,
/// reproducir/pausar, siguiente y, solo en la vista expandida, repetir.
List<MediaControl> notificationControls({required bool playing, required AudioServiceRepeatMode repeat}) => [
      MediaControl.skipToPrevious,
      if (playing) MediaControl.pause else MediaControl.play,
      MediaControl.skipToNext,
      repeatControl(repeat),
    ];

/// La vista compacta enseña tres: anterior, reproducir/pausar y siguiente.
const List<int> kNotificationCompactIndices = [0, 1, 2];
