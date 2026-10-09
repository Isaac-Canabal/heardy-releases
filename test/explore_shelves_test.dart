// Widgets de presentación de Explorar. Las pantallas completas (ExploreScreen,
// colecciones) leen el AudioPlayerHandler real vía RemoteTrackActionsMixin y no
// se pueden montar sin un fake de just_audio; por eso la lógica está en
// funciones puras y estos widgets son sólo presentación.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:heardy/l10n/app_localizations.dart';
import 'package:heardy/models/explore.dart';
import 'package:heardy/models/song.dart';
import 'package:heardy/providers/explore_provider.dart';
import 'package:heardy/widgets/explore_shelves.dart';

Widget _host(Widget child) => MaterialApp(
      locale: const Locale('es'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

Song _song(String id) => Song(
      id: id,
      title: 'Canción $id',
      artist: 'Artista',
      duration: 100,
      filePath: '',
      artPath: '',
      format: 'm4a',
      downloadDate: DateTime(2026, 1, 1),
    );

void main() {
  group('ExploreShelfFrame', () {
    Widget frame(ShelfState<List<int>> state, {VoidCallback? onRetry, Widget? empty}) => _host(
          ExploreShelfFrame<List<int>>(
            title: 'Mi estantería',
            state: state,
            onRetry: onRetry ?? () {},
            skeleton: const Text('skeleton'),
            isEmpty: (d) => d.isEmpty,
            emptyState: empty,
            builder: (d) => Text('datos ${d.length}'),
          ),
        );

    testWidgets('sin datos aún muestra cabecera y esqueleto', (tester) async {
      await tester.pumpWidget(frame(const ShelfState.loading()));
      expect(find.text('Mi estantería'), findsOneWidget);
      expect(find.text('skeleton'), findsOneWidget);
    });

    testWidgets('con datos los pinta; un refresco conserva los anteriores', (tester) async {
      await tester.pumpWidget(frame(const ShelfState.loading([1, 2])));
      expect(find.text('datos 2'), findsOneWidget);
      expect(find.text('skeleton'), findsNothing);
    });

    testWidgets('error sin datos: mensaje localizado y Reintentar llama a onRetry', (tester) async {
      var retries = 0;
      await tester.pumpWidget(frame(ShelfState.error(Exception('x')), onRetry: () => retries++));
      expect(find.text('No se pudo cargar esta sección'), findsOneWidget);
      await tester.tap(find.byKey(const Key('explore_shelf_retry')));
      expect(retries, 1);
    });

    testWidgets('vacío: se oculta salvo que haya emptyState', (tester) async {
      await tester.pumpWidget(frame(const ShelfState.data([])));
      expect(find.text('Mi estantería'), findsNothing);

      await tester.pumpWidget(frame(const ShelfState.data([]), empty: const Text('nada')));
      expect(find.text('Mi estantería'), findsOneWidget);
      expect(find.text('nada'), findsOneWidget);
    });
  });

  testWidgets('QuickPicksGrid pinta las canciones y avisa del toque', (tester) async {
    Song? tapped;
    await tester.pumpWidget(_host(QuickPicksGrid(
      columns: [
        [_song('a'), _song('b')],
        [_song('c')],
      ],
      onTap: (s) => tapped = s,
    )));
    expect(find.text('Canción a'), findsOneWidget);
    expect(find.text('Canción b'), findsOneWidget);
    await tester.tap(find.byKey(const Key('quick_pick_b')));
    expect(tapped?.id, 'b');
  });

  testWidgets('ArtistAvatarsRow muestra la inicial y abre al tocar', (tester) async {
    String? tapped;
    await tester.pumpWidget(_host(ArtistAvatarsRow(artists: const ['bad bunny'], onTap: (a) => tapped = a)));
    expect(find.text('B'), findsOneWidget);
    await tester.tap(find.byKey(const Key('explore_artist_bad bunny')));
    expect(tapped, 'bad bunny');
  });

  testWidgets('MoodChipsRow lista los ánimos y avisa del toque', (tester) async {
    ExploreMood? tapped;
    await tester.pumpWidget(_host(MoodChipsRow(
      moods: const [ExploreMood(title: 'Relax', params: 'p1'), ExploreMood(title: 'Fiesta', params: 'p2')],
      onTap: (m) => tapped = m,
    )));
    await tester.tap(find.byKey(const Key('mood_chip_p2')));
    expect(tapped?.title, 'Fiesta');
  });

  testWidgets('ExploreHintCard con acción', (tester) async {
    var pressed = false;
    await tester.pumpWidget(_host(ExploreHintCard(
      title: 'T',
      body: 'B',
      actionLabel: 'Entrar',
      onAction: () => pressed = true,
    )));
    await tester.tap(find.byKey(const Key('explore_hint_action')));
    expect(pressed, isTrue);
  });

  test('albumSubtitle une artista y año sin separadores sobrantes', () {
    expect(albumSubtitle(const ExploreAlbum(browseId: 'x', title: 't', artist: 'A', year: '2026')), 'A · 2026');
    expect(albumSubtitle(const ExploreAlbum(browseId: 'x', title: 't', artist: 'A')), 'A');
    expect(albumSubtitle(const ExploreAlbum(browseId: 'x', title: 't')), '');
  });

  testWidgets('ArtistAvatarsRow muestra progreso en el artista que se resuelve', (tester) async {
    await tester.pumpWidget(_host(ArtistAvatarsRow(
      artists: const ['bad bunny', 'rosalia'],
      onTap: (_) {},
      loadingArtist: 'bad bunny',
    )));
    expect(find.byKey(const Key('explore_artist_loading')), findsOneWidget);
    expect(find.text('B'), findsNothing);
    expect(find.text('R'), findsOneWidget);
  });

  testWidgets('ExploreRelatedArtistsRow lista artistas y avisa del toque', (tester) async {
    ExploreRelatedArtist? tapped;
    await tester.pumpWidget(_host(ExploreRelatedArtistsRow(
      artists: const [ExploreRelatedArtist(channelId: 'UC1', name: 'Miley')],
      onTap: (a) => tapped = a,
    )));
    expect(find.text('Miley'), findsOneWidget);
    await tester.tap(find.byKey(const Key('explore_related_UC1')));
    expect(tapped?.channelId, 'UC1');
  });
}
