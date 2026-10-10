import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:heardy/services/shuffle_logic.dart';

void main() {
  final items = List.generate(10, (i) => 'song$i');

  group('shuffleKeepingCurrent', () {
    test('la pista actual queda primera y es una permutación completa', () {
      final out = shuffleKeepingCurrent(items, 4, Random(1));
      expect(out.first, 'song4');
      expect(out.length, items.length);
      expect(out.toSet(), items.toSet());
    });

    test('es estable con la misma semilla', () {
      expect(
        shuffleKeepingCurrent(items, 2, Random(7)),
        shuffleKeepingCurrent(items, 2, Random(7)),
      );
    });

    test('realmente cambia el orden del resto', () {
      final out = shuffleKeepingCurrent(items, 0, Random(3));
      expect(out.sublist(1), isNot(items.sublist(1)));
    });

    test('no muta la lista original', () {
      final copy = List<String>.of(items);
      shuffleKeepingCurrent(items, 3, Random(2));
      expect(items, copy);
    });

    test('índice fuera de rango baraja todo; cola vacía o de una', () {
      expect(shuffleKeepingCurrent(items, -1, Random(1)).toSet(), items.toSet());
      expect(shuffleKeepingCurrent(<String>[], 0, Random(1)), isEmpty);
      expect(shuffleKeepingCurrent(['a'], 0, Random(1)), ['a']);
    });

    test('siguiente/anterior lineales sobre la cola barajada recorren todo una vez', () {
      final out = shuffleKeepingCurrent(items, 5, Random(9));
      final visited = <String>[];
      for (var i = 0; i < out.length; i++) {
        visited.add(out[i]);
      }
      expect(visited.first, 'song5');
      expect(visited.toSet().length, items.length);
      // "anterior" desde la segunda vuelve a la actual original.
      expect(out[1 - 1], 'song5');
    });
  });

  group('restoreOriginalOrder', () {
    String key(String s) => s;

    test('al desactivar vuelve al orden original', () {
      final shuffled = shuffleKeepingCurrent(items, 6, Random(4));
      expect(restoreOriginalOrder(shuffled, items, key), items);
    });

    test('descarta lo quitado y deja al final lo añadido mientras estaba barajado', () {
      final shuffled = shuffleKeepingCurrent(items, 1, Random(5))
        ..remove('song3')
        ..add('nueva');
      final restored = restoreOriginalOrder(shuffled, items, key);
      expect(restored, [...items.where((s) => s != 'song3'), 'nueva']);
    });

    test('sin duplicados aunque el original los traiga', () {
      expect(restoreOriginalOrder(['a', 'b'], ['a', 'a', 'b'], key), ['a', 'b']);
    });
  });

  test('sameQueueIds', () {
    expect(sameQueueIds(['a', 'b'], ['a', 'b']), isTrue);
    expect(sameQueueIds(['a', 'b'], ['b', 'a']), isFalse);
    expect(sameQueueIds(['a'], ['a', 'b']), isFalse);
  });
}
