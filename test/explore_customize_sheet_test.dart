import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:heardy/l10n/app_localizations.dart';
import 'package:heardy/providers/explore_provider.dart';
import 'package:heardy/providers/settings_provider.dart';
import 'package:heardy/widgets/explore_customize_sheet.dart';

Widget _host(SettingsProvider settings, {VoidCallback? onChanged, Locale locale = const Locale('es')}) =>
    ChangeNotifierProvider.value(
      value: settings,
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: SingleChildScrollView(child: ExploreCustomizeSheet(onChanged: onChanged))),
      ),
    );

Future<SettingsProvider> _settings() async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsProvider();
  await settings.ensureLoaded();
  return settings;
}

void main() {
  testWidgets('un interruptor por sección oculta y muestra, y avisa del cambio', (tester) async {
    final settings = await _settings();
    var changes = 0;
    await tester.pumpWidget(_host(settings, onChanged: () => changes++));
    await tester.pumpAndSettle();

    for (final id in ExploreShelfId.values) {
      expect(find.byKey(Key('explore_section_switch_${id.name}')), findsOneWidget);
    }
    expect(tester.widget<Switch>(find.byType(Switch).first).value, isTrue);

    await tester.tap(find.byKey(const Key('explore_section_switch_charts')));
    await tester.pumpAndSettle();
    expect(settings.exploreHiddenShelves, {ExploreShelfId.charts});
    expect(changes, 1);

    await tester.tap(find.byKey(const Key('explore_section_switch_charts')));
    await tester.pumpAndSettle();
    expect(settings.exploreHiddenShelves, isEmpty);
    expect(changes, 2);
  });

  testWidgets('el selector de país busca, elige y vuelve a automático', (tester) async {
    final settings = await _settings();
    var changes = 0;
    await tester.pumpWidget(_host(settings, onChanged: () => changes++));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('explore_country_tile')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('explore_country_automatic')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('explore_country_search')), 'mexi');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('explore_country_ES')), findsNothing);
    await tester.tap(find.byKey(const Key('explore_country_MX')));
    await tester.pumpAndSettle();
    expect(settings.exploreCountry, 'MX');
    expect(changes, 1);

    await tester.tap(find.byKey(const Key('explore_country_tile')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('explore_country_automatic')));
    await tester.pumpAndSettle();
    expect(settings.exploreCountry, isNull);
    expect(changes, 2);
  });

  testWidgets('sin resultados muestra el aviso', (tester) async {
    final settings = await _settings();
    await tester.pumpWidget(_host(settings));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('explore_country_tile')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('explore_country_search')), 'xyzxyz');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('explore_country_empty')), findsOneWidget);
  });
}
