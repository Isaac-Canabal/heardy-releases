import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:heardy/services/download_source.dart';
import 'package:heardy/services/stream_queue_logic.dart';

RemoteTrack t(String id) => RemoteTrack(
      id: id,
      title: 'T$id',
      artist: 'A',
      album: null,
      durationSeconds: 100,
      thumbnailUrl: '',
      sourceUrl: '',
    );

void main() {
  group('nextStreamIndex / previousStreamIndex', () {
    test('avanza dentro de la cola y termina en la última', () {
      expect(nextStreamIndex(0, 3), 1);
      expect(nextStreamIndex(1, 3), 2);
      expect(nextStreamIndex(2, 3), isNull);
      expect(nextStreamIndex(0, 0), isNull);
    });

    test('retrocede hasta la primera', () {
      expect(previousStreamIndex(2, 3), 1);
      expect(previousStreamIndex(0, 3), isNull);
    });
  });

  group('streamPreResolveIndex', () {
    test('pre-resuelve sólo la siguiente, y nada tras la última', () {
      expect(streamPreResolveIndex(0, 5), 1);
      expect(streamPreResolveIndex(3, 5), 4);
      expect(streamPreResolveIndex(4, 5), isNull);
    });
  });

  group('prefetchMatches', () {
    test('sólo reutiliza una resolución del mismo vídeo', () {
      expect(prefetchMatches('a', 'a'), isTrue);
      expect(prefetchMatches('a', 'b'), isFalse);
      expect(prefetchMatches(null, 'b'), isFalse);
    });
  });

  group('decideAfterStreamFailure', () {
    test('salta a la siguiente y avisa la primera vez', () {
      final d = decideAfterStreamFailure(
        index: 1,
        length: 5,
        consecutiveFailures: 1,
        noticeAlreadyEmitted: false,
      );
      expect(d.nextIndex, 2);
      expect(d.notify, isTrue);
    });

    test('no vuelve a avisar en la misma ejecución', () {
      final d = decideAfterStreamFailure(
        index: 1,
        length: 5,
        consecutiveFailures: 2,
        noticeAlreadyEmitted: true,
      );
      expect(d.nextIndex, 2);
      expect(d.notify, isFalse);
    });

    test('se detiene al llegar al tope de fallos seguidos', () {
      final d = decideAfterStreamFailure(
        index: 1,
        length: 10,
        consecutiveFailures: maxConsecutiveStreamFailures,
        noticeAlreadyEmitted: true,
      );
      expect(d.nextIndex, isNull);
    });

    test('se detiene si falla la última pista y avisa si no se había avisado', () {
      final d = decideAfterStreamFailure(
        index: 4,
        length: 5,
        consecutiveFailures: 1,
        noticeAlreadyEmitted: false,
      );
      expect(d.nextIndex, isNull);
      expect(d.notify, isTrue);
    });
  });

  group('shouldResetStreamFailures', () {
    test('sólo tras sonar un rato', () {
      expect(shouldResetStreamFailures(const Duration(seconds: 2)), isFalse);
      expect(shouldResetStreamFailures(streamPlayedOkThreshold), isTrue);
    });
  });

  group('buildStreamQueue', () {
    test('ubica la pista inicial y descarta ids vacíos y repetidos', () {
      final seed = buildStreamQueue([t('a'), t(''), t('b'), t('a'), t('c')], 'c');
      expect(seed.tracks.map((e) => e.id), ['a', 'b', 'c']);
      expect(seed.startIndex, 2);
    });

    test('empieza en 0 si la pista inicial no está', () {
      final seed = buildStreamQueue([t('a'), t('b')], 'zzz');
      expect(seed.startIndex, 0);
    });

    test('lista vacía queda vacía', () {
      final seed = buildStreamQueue(const [], 'a');
      expect(seed.tracks, isEmpty);
      expect(seed.startIndex, 0);
    });
  });

  group('streamMediaItem', () {
    test('sin URL ni rutas: extras de stream y arte sólo https', () {
      final item = streamMediaItem(RemoteTrack(
        id: 'x',
        title: 'Tx',
        artist: 'A',
        album: 'Al',
        durationSeconds: 90,
        thumbnailUrl: 'https://i.ytimg.com/a.jpg',
        sourceUrl: '',
      ));
      expect(item.id, 'stream:x');
      expect(item.duration, const Duration(seconds: 90));
      expect(item.artUri, Uri.parse('https://i.ytimg.com/a.jpg'));
      expect(item.extras, {
        'isStream': true,
        'videoId': 'x',
        'filePath': '',
        'artPath': '',
      });
    });

    test('la duración resuelta gana y miniatura no https se descarta', () {
      final item = streamMediaItem(t('y'), resolvedSeconds: 200);
      expect(item.duration, const Duration(seconds: 200));
      expect(item.artUri, isNull);
      expect(streamMediaItem(t('z'), resolvedSeconds: 0).duration, const Duration(seconds: 100));
    });
  });

  group('publishedStreamQueue', () {
    test('reemplaza sólo la pista actual y conserva el orden', () {
      final items = [for (final id in ['a', 'b', 'c']) streamMediaItem(t(id))];
      final current = streamMediaItem(t('b'), resolvedSeconds: 250);
      final out = publishedStreamQueue(items, 1, current);
      expect(out.map((e) => e.id), ['stream:a', 'stream:b', 'stream:c']);
      expect(out[1].duration, const Duration(seconds: 250));
      expect(out[0], same(items[0]));
      expect(items[1].duration, const Duration(seconds: 100));
    });

    test('índice fuera de rango deja la lista igual', () {
      final items = [streamMediaItem(t('a'))];
      expect(publishedStreamQueue(items, 3, items[0]).single, same(items[0]));
    });
  });

  group('streamJumpTarget', () {
    test('sólo índices válidos', () {
      expect(streamJumpTarget(0, 3), 0);
      expect(streamJumpTarget(2, 3), 2);
      expect(streamJumpTarget(3, 3), isNull);
      expect(streamJumpTarget(-1, 3), isNull);
    });
  });

  group('streamIndexForPlayback', () {
    test('con cola de streaming manda su índice, no el del player', () {
      expect(streamIndexForPlayback(streamQueueActive: true, streamIndex: 4, playerIndex: 0), 4);
      expect(streamIndexForPlayback(streamQueueActive: false, streamIndex: 4, playerIndex: 2), 2);
      expect(streamIndexForPlayback(streamQueueActive: false, streamIndex: 4, playerIndex: null), isNull);
    });
  });

  group('arte remoto', () {
    test('la cola publicada lleva artUri https agrandado', () {
      final item = streamMediaItem(RemoteTrack(
        id: 'x',
        title: 'T',
        artist: 'A',
        album: null,
        durationSeconds: 1,
        thumbnailUrl: 'https://lh3.googleusercontent.com/abc=w120-h120-l90-rj',
        sourceUrl: '',
      ));
      expect(item.artUri.toString(), contains('=w544-h544'));
    });

    test('remoteArtUrlFor: sólo sin archivo local y con http(s)', () {
      final remote = Uri.parse('https://i.ytimg.com/a.jpg');
      expect(remoteArtUrlFor('', remote), 'https://i.ytimg.com/a.jpg');
      expect(remoteArtUrlFor('/data/art.jpg', remote), isNull);
      expect(remoteArtUrlFor('', null), isNull);
      expect(remoteArtUrlFor('', Uri.parse('content://x/y')), isNull);
      expect(remoteArtUrlFor('', Uri.parse('file:///a.jpg')), isNull);
    });
  });

  group('StreamLoadGeneration', () {
    test('sólo la última generación es vigente', () {
      final g = StreamLoadGeneration();
      final a = g.begin();
      expect(g.isCurrent(a), isTrue);
      final b = g.begin();
      expect(g.isCurrent(a), isFalse);
      expect(g.isCurrent(b), isTrue);
    });

    test('invalidate descarta lo que estaba en vuelo', () {
      final g = StreamLoadGeneration();
      final a = g.begin();
      g.invalidate();
      expect(g.isCurrent(a), isFalse);
    });

    // Mismo patrón que `_loadStreamQueueFrom`: comprobar tras cada await.
    Future<void> load(StreamLoadGeneration g, int index, Future<void> resolve, List<int> applied) async {
      final gen = g.begin();
      await resolve;
      if (!g.isCurrent(gen)) return;
      applied.add(index);
    }

    test('A y luego B rápido: sólo se aplica B aunque A resuelva después', () async {
      final g = StreamLoadGeneration();
      final applied = <int>[];
      final a = Completer<void>();
      final b = Completer<void>();
      final fa = load(g, 1, a.future, applied);
      final fb = load(g, 2, b.future, applied);
      b.complete();
      await fb;
      a.complete();
      await fa;
      expect(applied, [2]);
    });

    test('A resuelve antes de B pero ya fue superada: se descarta', () async {
      final g = StreamLoadGeneration();
      final applied = <int>[];
      final a = Completer<void>();
      final b = Completer<void>();
      final fa = load(g, 1, a.future, applied);
      final fb = load(g, 2, b.future, applied);
      a.complete();
      await fa;
      expect(applied, isEmpty);
      b.complete();
      await fb;
      expect(applied, [2]);
    });
  });

  group('StreamTargetDebouncer', () {
    test('toques rápidos disparan sólo el último destino', () async {
      final fired = <int>[];
      final d = StreamTargetDebouncer(const Duration(milliseconds: 30), fired.add);
      d.select(1);
      d.select(2);
      d.select(3);
      expect(d.isPending, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(fired, [3]);
      expect(d.isPending, isFalse);
    });

    test('cancel evita el disparo', () async {
      final fired = <int>[];
      final d = StreamTargetDebouncer(const Duration(milliseconds: 20), fired.add);
      d.select(1);
      d.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(fired, isEmpty);
    });

    test('toques separados disparan cada uno', () async {
      final fired = <int>[];
      final d = StreamTargetDebouncer(const Duration(milliseconds: 20), fired.add);
      d.select(1);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      d.select(2);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(fired, [1, 2]);
    });
  });

  group('decideStreamPrevious', () {
    test('cargada y pasados 3 s: reinicia la pista', () {
      final r = decideStreamPrevious(
          index: 2, length: 5, position: const Duration(seconds: 5), loaded: true);
      expect(r.restart, isTrue);
      expect(r.target, isNull);
    });

    test('cargada y al inicio: va a la anterior', () {
      final r = decideStreamPrevious(
          index: 2, length: 5, position: const Duration(seconds: 1), loaded: true);
      expect(r.restart, isFalse);
      expect(r.target, 1);
    });

    test('mientras carga ignora la posición (es de la pista vieja): va a la anterior', () {
      final r = decideStreamPrevious(
          index: 3, length: 5, position: const Duration(seconds: 90), loaded: false);
      expect(r.restart, isFalse);
      expect(r.target, 2);
    });

    test('en la primera pista cargada: reinicia', () {
      final r = decideStreamPrevious(
          index: 0, length: 5, position: const Duration(seconds: 1), loaded: true);
      expect(r.restart, isTrue);
      expect(r.target, isNull);
    });

    test('en la primera pista sin cargar: recarga la misma', () {
      final r = decideStreamPrevious(
          index: 0, length: 5, position: Duration.zero, loaded: false);
      expect(r.restart, isFalse);
      expect(r.target, 0);
    });

    test('previous tras saltos rápidos aterriza en el índice seleccionado - 1', () {
      // 0 -> 1 -> 2 -> 3 seleccionados sin cargar; previous parte de 3, no de 0.
      final r = decideStreamPrevious(
          index: 3, length: 10, position: const Duration(seconds: 40), loaded: false);
      expect(r.target, 2);
    });
  });

  group('streamQueueNeedsRepublish', () {
    test('sólo si cambia la duración resuelta', () {
      final a = streamMediaItem(t('a'));
      expect(streamQueueNeedsRepublish(a, streamMediaItem(t('a'))), isFalse);
      expect(streamQueueNeedsRepublish(a, streamMediaItem(t('a'), resolvedSeconds: 200)), isTrue);
    });
  });
}
