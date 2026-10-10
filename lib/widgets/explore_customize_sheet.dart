import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/settings_provider.dart';
import '../services/explore_logic.dart';
import '../theme/app_theme.dart';

String exploreShelfLabel(AppLocalizations l10n, ExploreShelfId id) => switch (id) {
      ExploreShelfId.recent => l10n.exploreRecentTitle,
      ExploreShelfId.artists => l10n.exploreArtistsTitle,
      ExploreShelfId.radio => l10n.exploreRadioTitle,
      ExploreShelfId.charts => l10n.exploreChartsTitle,
      ExploreShelfId.newReleases => l10n.exploreNewReleasesTitle,
      ExploreShelfId.home => l10n.exploreSectionHome,
      ExploreShelfId.moods => l10n.exploreSectionMoods,
    };

bool _isEnglish(BuildContext context) => Localizations.localeOf(context).languageCode == 'en';

/// Abre la hoja de personalización de Explorar. [onChanged] se llama tras cada
/// cambio ya guardado, para que la pantalla le pida al provider aplicarlo.
Future<void> showExploreCustomizeSheet(BuildContext context, {VoidCallback? onChanged}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => SafeArea(
      child: SingleChildScrollView(child: ExploreCustomizeSheet(onChanged: onChanged)),
    ),
  );
}

/// Elegir país para las listas regionales; null en el selector es "Automático".
Future<void> showExploreCountryPicker(BuildContext context, {VoidCallback? onChanged}) {
  final settings = context.read<SettingsProvider>();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => _ExploreCountryPicker(
      selected: settings.exploreCountry,
      english: _isEnglish(context),
      onPick: (code) async {
        Navigator.of(sheetContext).pop();
        await settings.setExploreCountry(code);
        onChanged?.call();
      },
    ),
  );
}

class ExploreCustomizeSheet extends StatelessWidget {
  final VoidCallback? onChanged;
  const ExploreCustomizeSheet({super.key, this.onChanged});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final settings = context.watch<SettingsProvider>();
    final hidden = settings.exploreHiddenShelves;
    final country = settings.exploreCountry;
    final countryName = country == null
        ? l10n.exploreCountryAutomatic
        : kExploreCountries
            .firstWhere((c) => c.code == country)
            .nameFor(english: _isEnglish(context));
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Text(
            l10n.exploreCustomizeTitle,
            style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800),
          ),
        ),
        _label(l10n.exploreCustomizeSections),
        for (final id in ExploreShelfId.values)
          SwitchListTile(
            key: Key('explore_section_switch_${id.name}'),
            title: Text(exploreShelfLabel(l10n, id)),
            value: !hidden.contains(id),
            onChanged: (visible) async {
              await settings.setExploreShelfHidden(id, !visible);
              onChanged?.call();
            },
          ),
        _label(l10n.exploreCustomizeCountry),
        ListTile(
          key: const Key('explore_country_tile'),
          leading: Icon(Icons.public_rounded, color: AppTheme.primaryLight),
          title: Text(countryName),
          subtitle: Text(l10n.exploreCustomizeCountryNote),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => showExploreCountryPicker(context, onChanged: onChanged),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
        child: Text(text, style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 13)),
      );
}

class _ExploreCountryPicker extends StatefulWidget {
  final String? selected;
  final bool english;
  final void Function(String? code) onPick;

  const _ExploreCountryPicker({required this.selected, required this.english, required this.onPick});

  @override
  State<_ExploreCountryPicker> createState() => _ExploreCountryPickerState();
}

class _ExploreCountryPickerState extends State<_ExploreCountryPicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final matches = filterExploreCountries(_query, english: widget.english);
    final height = MediaQuery.sizeOf(context).height * 0.75;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: height,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: TextField(
                key: const Key('explore_country_search'),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search_rounded),
                  hintText: l10n.exploreCountrySearchHint,
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  if (_query.trim().isEmpty)
                    ListTile(
                      key: const Key('explore_country_automatic'),
                      title: Text(l10n.exploreCountryAutomatic),
                      subtitle: Text(l10n.exploreCountryAutomaticHint),
                      trailing: widget.selected == null ? const Icon(Icons.check_rounded) : null,
                      onTap: () => widget.onPick(null),
                    ),
                  for (final c in matches)
                    ListTile(
                      key: Key('explore_country_${c.code}'),
                      title: Text(c.nameFor(english: widget.english)),
                      trailing: widget.selected == c.code ? const Icon(Icons.check_rounded) : null,
                      onTap: () => widget.onPick(c.code),
                    ),
                  if (matches.isEmpty)
                    Padding(
                      key: const Key('explore_country_empty'),
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        l10n.exploreCountryNoResults,
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
