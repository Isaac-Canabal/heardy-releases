import 'dart:typed_data';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heardy/l10n/app_localizations.dart';
import 'package:heardy/screens/now_playing_screen.dart';
import 'package:heardy/widgets/waveform_seek_bar.dart';

Widget _host(
  MediaItem item,
  Future<Uint8List?> Function(String, String) loader, {
  bool inline = false,
}) {
  return MaterialApp(
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 400,
          child: WaveformSeekSection(
            mediaItem: item,
            positionStream: const Stream<Duration>.empty(),
            onSeek: (_) {},
            inline: inline,
            loadPeaks: loader,
          ),
        ),
      ),
    ),
  );
}

MediaItem _item({Map<String, dynamic>? extras}) => MediaItem(
      id: 'song-1',
      title: 'T',
      duration: const Duration(seconds: 100),
      extras: extras ?? {'filePath': 'C:/m/a.m4a'},
    );

void main() {
  final peaks = Uint8List.fromList(List.filled(50, 128));

  testWidgets('muestra la onda cuando la carga devuelve picos', (t) async {
    await t.pumpWidget(_host(_item(), (_, _) async => peaks, inline: true));
    await t.pump();
    expect(find.byType(WaveformSeekBar), findsOneWidget);
    expect(find.byType(Slider), findsNothing);
  });

  testWidgets('sin picos (ffmpeg ausente) queda el Slider', (t) async {
    await t.pumpWidget(_host(_item(), (_, _) async => null));
    await t.pump();
    expect(find.byType(Slider), findsOneWidget);
    expect(find.byType(WaveformSeekBar), findsNothing);
  });

  testWidgets('si la extracción lanza, queda el Slider', (t) async {
    await t.pumpWidget(
      _host(_item(), (_, _) async => throw Exception('ffmpeg')),
    );
    await t.pump();
    expect(find.byType(Slider), findsOneWidget);
  });

  testWidgets('streams no cargan onda', (t) async {
    var calls = 0;
    await t.pumpWidget(
      _host(_item(extras: {'filePath': 'x', 'isStream': true}), (_, _) async {
        calls++;
        return peaks;
      }),
    );
    await t.pump();
    expect(calls, 0);
    expect(find.byType(Slider), findsOneWidget);
  });
}
