// Cubre `shouldRecordPlay`, la única pieza de la lógica de estadísticas de
// reproducción que es una función pura y por tanto testeable sin un doble de
// `just_audio` (que este codebase no tiene — ver CLAUDE.md, "Testing").
import 'package:flutter_test/flutter_test.dart';

import 'package:heardy/services/audio_player_handler.dart';

void main() {
  group('shouldRecordPlay', () {
    test('por debajo del 50% no cuenta', () {
      expect(
        shouldRecordPlay(
          listened: const Duration(seconds: 89),
          duration: const Duration(seconds: 180),
        ),
        isFalse,
      );
    });

    test('al 50% exacto o más sí cuenta', () {
      expect(
        shouldRecordPlay(
          listened: const Duration(seconds: 90),
          duration: const Duration(seconds: 180),
        ),
        isTrue,
      );
      expect(
        shouldRecordPlay(
          listened: const Duration(seconds: 180),
          duration: const Duration(seconds: 180),
        ),
        isTrue,
      );
    });

    test('el umbral se redondea hacia arriba, nunca a favor del usuario', () {
      // 50% de 181s son 90.5s → 91, no 90.
      expect(
        shouldRecordPlay(
          listened: const Duration(seconds: 90),
          duration: const Duration(seconds: 181),
        ),
        isFalse,
      );
      expect(
        shouldRecordPlay(
          listened: const Duration(seconds: 91),
          duration: const Duration(seconds: 181),
        ),
        isTrue,
      );
    });

    test('duración desconocida o inválida nunca cuenta', () {
      expect(
        shouldRecordPlay(
          listened: const Duration(seconds: 30),
          duration: Duration.zero,
        ),
        isFalse,
      );
    });
  });

  // `shouldPersistPlaybackState` existe por el backend de escritorio
  // (libmpv vía just_audio_media_kit): su `playbackEventStream` emite
  // decenas de veces por segundo mientras suena, y cada evento escribía
  // SharedPreferences a disco — 600+ escrituras en medio minuto, medido en
  // la app real. ExoPlayer no tiene ese problema, así que en Android no se
  // consulta.
  group('shouldPersistPlaybackState', () {
    final base = DateTime(2026, 1, 1, 12, 0, 0);
    PlaybackSaveSnapshot snap({
      String mediaId = 'a',
      bool playing = true,
      int queueLength = 3,
      Duration after = Duration.zero,
    }) =>
        PlaybackSaveSnapshot(
          mediaId: mediaId,
          playing: playing,
          queueLength: queueLength,
          savedAt: base.add(after),
        );

    test('la primera vez siempre guarda', () {
      expect(shouldPersistPlaybackState(previous: null, next: snap()), isTrue);
    });

    test('el mismo estado poco después no vuelve a escribir', () {
      expect(
        shouldPersistPlaybackState(
          previous: snap(),
          next: snap(after: const Duration(seconds: 1)),
        ),
        isFalse,
      );
    });

    test('cambiar de canción, pausar o cambiar la cola guarda al instante', () {
      expect(shouldPersistPlaybackState(previous: snap(), next: snap(mediaId: 'b')), isTrue);
      expect(shouldPersistPlaybackState(previous: snap(), next: snap(playing: false)), isTrue);
      expect(shouldPersistPlaybackState(previous: snap(), next: snap(queueLength: 4)), isTrue);
    });

    test('la posición se refresca al pasar el intervalo mínimo', () {
      expect(
        shouldPersistPlaybackState(
          previous: snap(),
          next: snap(after: const Duration(seconds: 5)),
        ),
        isTrue,
      );
    });
  });
}
