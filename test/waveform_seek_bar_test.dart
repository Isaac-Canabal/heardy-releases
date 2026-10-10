import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heardy/widgets/waveform_seek_bar.dart';

Widget _host({
  required List<Duration> seeks,
  List<Duration?>? scrubs,
  double inset = 0,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 200,
          child: WaveformSeekBar(
            peaks: Uint8List.fromList(List.filled(50, 128)),
            position: Duration.zero,
            duration: const Duration(seconds: 100),
            onSeek: seeks.add,
            onScrub: scrubs?.add,
            horizontalInset: inset,
            activeColor: Colors.blue,
            inactiveColor: Colors.grey,
            semanticsLabel: 'Progreso',
            semanticsValue: '0:00 de 1:40',
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('tap hace seek una vez en la fracción tocada', (tester) async {
    final seeks = <Duration>[];
    await tester.pumpWidget(_host(seeks: seeks));
    final left = tester.getTopLeft(find.byType(WaveformSeekBar));
    await tester.tapAt(left + const Offset(100, 10));
    expect(seeks, [const Duration(seconds: 50)]);
  });

  testWidgets('arrastrar hace seek sólo al soltar', (tester) async {
    final seeks = <Duration>[];
    final scrubs = <Duration?>[];
    await tester.pumpWidget(_host(seeks: seeks, scrubs: scrubs));
    final left = tester.getTopLeft(find.byType(WaveformSeekBar));
    final g = await tester.startGesture(left + const Offset(20, 10));
    await g.moveBy(const Offset(40, 0));
    await g.moveBy(const Offset(40, 0));
    expect(seeks, isEmpty);
    await g.up();
    expect(seeks.length, 1);
    expect(seeks.single, const Duration(seconds: 50));
    expect(scrubs.last, isNull);
  });

  testWidgets('expone semántica de slider', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(seeks: []));
    expect(find.bySemanticsLabel('Progreso'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('con inset, el borde interior mapea a 0 y al total', (t) async {
    final seeks = <Duration>[];
    await t.pumpWidget(_host(seeks: seeks, inset: 20));
    final left = t.getTopLeft(find.byType(WaveformSeekBar));
    await t.tapAt(left + const Offset(20, 10));
    await t.tapAt(left + const Offset(180, 10));
    await t.tapAt(left + const Offset(2, 10));
    await t.tapAt(left + const Offset(198, 10));
    expect(seeks, [
      Duration.zero,
      const Duration(seconds: 100),
      Duration.zero,
      const Duration(seconds: 100),
    ]);
  });
}
