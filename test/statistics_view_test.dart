// `StatisticsView` no toca la base de datos ni ningún Provider: recibe un
// `StatisticsData` ya cargado. Por eso estos son `testWidgets` normales — sin
// `tester.runAsync`, sin sqflite_common_ffi y sin árbol de providers, al
// contrario que `import_screen_test.dart`. Ésa es justamente la ventaja que
// compró extraer estos widgets de `settings_screen.dart` en la Fase 1.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heardy/l10n/app_localizations.dart';
import 'package:heardy/models/statistics_data.dart';
import 'package:heardy/widgets/statistics_view.dart';

StatisticsData _data({int songs = 3, int artists = 2, int totalPlays = 10}) {
  return StatisticsData(
    totalPlays: totalPlays,
    totalListenSeconds: 3660,
    topArtists: List.generate(
      artists,
      (i) => TopArtistStat(name: 'Artista $i', playCount: artists - i),
    ),
    topSongs: List.generate(
      songs,
      (i) => TopSongStat(
        songId: 's$i',
        title: 'Canción $i',
        artist: 'Artista $i',
        artPath: '',
        playCount: songs - i,
      ),
    ),
  );
}

/// Monta la vista y devuelve el `AppLocalizations` del árbol, para poder
/// comparar contra las cadenas reales de los `.arb` en vez de duplicarlas aquí.
Future<AppLocalizations> _pumpView(
  WidgetTester tester, {
  required StatisticsData? data,
  bool isWeek = true,
  ValueChanged<bool>? onPeriodChanged,
  bool expanded = false,
  VoidCallback? onToggleExpanded,
  bool decorated = true,
  String? headerLabel,
  Widget? trailing,
}) async {
  late AppLocalizations l10n;
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          child: Builder(
            builder: (context) {
              l10n = AppLocalizations.of(context)!;
              return StatisticsView(
                data: data,
                isWeek: isWeek,
                onPeriodChanged: onPeriodChanged,
                expanded: expanded,
                onToggleExpanded: onToggleExpanded,
                decorated: decorated,
                headerLabel: headerLabel,
                trailing: trailing,
              );
            },
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return l10n;
}

void main() {
  testWidgets('data null pinta el indicador de carga, conservando la cabecera', (tester) async {
    final l10n = await _pumpView(tester, data: null, onPeriodChanged: (_) {});

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(StatMiniCard), findsNothing);
    // La cabecera y el selector siguen ahí mientras carga: es como se veía
    // antes de la extracción, y evita que la tarjeta "salte" al llegar el dato.
    expect(find.text(l10n.statsYourActivity), findsOneWidget);
    expect(find.byType(PeriodToggle), findsOneWidget);
  });

  testWidgets('sin reproducciones muestra el texto de vacío y ninguna tarjeta', (tester) async {
    final l10n = await _pumpView(tester, data: const StatisticsData.empty());

    expect(find.text(l10n.statsEmptyHint), findsOneWidget);
    expect(find.byType(StatMiniCard), findsNothing);
    expect(find.byType(TopSongRow), findsNothing);
  });

  testWidgets('con datos pinta las dos tarjetas, los artistas y las canciones', (tester) async {
    final l10n = await _pumpView(tester, data: _data(songs: 3, artists: 2, totalPlays: 42));

    expect(find.byType(StatMiniCard), findsNWidgets(2));
    expect(find.text('42'), findsOneWidget);
    expect(find.text('1h 1m'), findsOneWidget); // 3660 s
    expect(find.text(l10n.statsTopArtists), findsOneWidget);
    expect(find.byType(TopArtistRow), findsNWidgets(2));
    expect(find.text(l10n.statsTopSongs), findsOneWidget);
    expect(find.byType(TopSongRow), findsNWidgets(3));
  });

  testWidgets('con 5 canciones o menos no hay chevron', (tester) async {
    await _pumpView(tester, data: _data(songs: 5), onToggleExpanded: () {});

    expect(find.byType(TopSongRow), findsNWidgets(5));
    expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsNothing);
  });

  testWidgets('con más de 5 muestra 5 y el chevron; desplegada las muestra todas', (tester) async {
    await _pumpView(tester, data: _data(songs: 8), onToggleExpanded: () {});
    expect(find.byType(TopSongRow), findsNWidgets(5));
    expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsOneWidget);

    await _pumpView(tester, data: _data(songs: 8), expanded: true, onToggleExpanded: () {});
    expect(find.byType(TopSongRow), findsNWidgets(8));
    expect(find.byIcon(Icons.keyboard_arrow_up_rounded), findsOneWidget);
  });

  testWidgets('el chevron llama a onToggleExpanded', (tester) async {
    var toggles = 0;
    await _pumpView(tester, data: _data(songs: 8), onToggleExpanded: () => toggles++);

    // Con 8 canciones el chevron queda fuera del alto del viewport de prueba,
    // así que hay que desplazarlo a la vista antes de tocarlo.
    final chevron = find.byIcon(Icons.keyboard_arrow_down_rounded);
    await tester.ensureVisible(chevron);
    await tester.pump();
    await tester.tap(chevron);
    await tester.pump();

    expect(toggles, 1);
  });

  testWidgets('sin onToggleExpanded no hay chevron aunque sobren canciones', (tester) async {
    await _pumpView(tester, data: _data(songs: 8));

    expect(find.byType(TopSongRow), findsNWidgets(5));
    expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsNothing);
  });

  testWidgets('sin onPeriodChanged no se dibuja el selector de periodo', (tester) async {
    await _pumpView(tester, data: _data());

    expect(find.byType(PeriodToggle), findsNothing);
  });

  testWidgets('tocar "Mes" avisa con false', (tester) async {
    bool? chosen;
    final l10n = await _pumpView(
      tester,
      data: _data(),
      onPeriodChanged: (isWeek) => chosen = isWeek,
    );

    await tester.tap(find.text(l10n.statsMonth));
    await tester.pump();

    expect(chosen, isFalse);
  });

  testWidgets('headerLabel reemplaza "Tu actividad" y trailing se pinta', (tester) async {
    final l10n = await _pumpView(
      tester,
      data: _data(),
      headerLabel: '@ana',
      trailing: const Icon(Icons.ios_share_rounded),
    );

    expect(find.text('@ana'), findsOneWidget);
    expect(find.text(l10n.statsYourActivity), findsNothing);
    expect(find.byIcon(Icons.ios_share_rounded), findsOneWidget);
  });

  testWidgets('título y artista vacíos caen a los textos traducidos', (tester) async {
    final l10n = await _pumpView(
      tester,
      data: const StatisticsData(
        totalPlays: 1,
        totalListenSeconds: 30,
        topArtists: [TopArtistStat(name: '', playCount: 1)],
        topSongs: [
          TopSongStat(songId: 's1', title: '', artist: '', artPath: '', playCount: 1),
        ],
      ),
    );

    expect(find.text(l10n.statsUntitledSong), findsOneWidget);
    expect(find.text(l10n.statsUnknownArtist), findsNWidgets(2)); // la fila del artista y la de la canción
  });
}
