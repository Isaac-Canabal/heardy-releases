import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/nav_tab.dart';

class NavTabDef {
  final NavTabId id;
  final IconData icon;
  final IconData selectedIcon;

  const NavTabDef({required this.id, required this.icon, required this.selectedIcon});

  String label(AppLocalizations l10n) => switch (id) {
        NavTabId.home => l10n.homeTitle,
        NavTabId.inbox => l10n.navInbox,
        NavTabId.add => l10n.navAdd,
        NavTabId.explore => l10n.exploreTitle,
        NavTabId.settings => l10n.settingsTitle,
      };
}

/// Una entrada por [NavTabId], en el orden del enum. De aquí salen la barra
/// inferior, la barra lateral y la hoja de ordenar.
const List<NavTabDef> kNavTabs = [
  NavTabDef(
    id: NavTabId.home,
    icon: Icons.library_music_outlined,
    selectedIcon: Icons.library_music_rounded,
  ),
  NavTabDef(
    id: NavTabId.inbox,
    icon: Icons.inbox_outlined,
    selectedIcon: Icons.inbox_rounded,
  ),
  NavTabDef(
    id: NavTabId.add,
    icon: Icons.cloud_download_outlined,
    selectedIcon: Icons.cloud_download_rounded,
  ),
  NavTabDef(
    id: NavTabId.explore,
    icon: Icons.explore_outlined,
    selectedIcon: Icons.explore_rounded,
  ),
  NavTabDef(
    id: NavTabId.settings,
    icon: Icons.settings_outlined,
    selectedIcon: Icons.settings_rounded,
  ),
];

NavTabDef navTabDef(NavTabId id) => kNavTabs[id.index];

/// Los destinos de la barra inferior en el orden visible [order].
List<NavigationDestination> navBarDestinations(
  AppLocalizations l10n,
  List<NavTabId> order, {
  required int Function(NavTabId id) badgeCount,
}) {
  Widget badged(IconData icon, int count) =>
      Badge(isLabelVisible: count > 0, label: Text('$count'), child: Icon(icon));

  return [
    for (final id in order)
      NavigationDestination(
        key: Key('nav_tab_${id.name}'),
        icon: badged(navTabDef(id).icon, badgeCount(id)),
        selectedIcon: badged(navTabDef(id).selectedIcon, badgeCount(id)),
        label: navTabDef(id).label(l10n),
      ),
  ];
}

/// Las pantallas de las pestañas. Van siempre en el orden del enum: reordenar
/// la barra no mueve nada aquí, así que ninguna pierde su estado.
class NavTabStack extends StatelessWidget {
  final NavTabId current;
  final Widget Function(NavTabId id) builder;

  const NavTabStack({super.key, required this.current, required this.builder});

  @override
  Widget build(BuildContext context) => IndexedStack(
        index: current.index,
        children: [for (final tab in kNavTabs) builder(tab.id)],
      );
}
