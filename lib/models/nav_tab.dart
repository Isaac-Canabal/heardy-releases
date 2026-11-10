/// Pestañas de navegación. Los nombres se guardan en preferencias: renombrar
/// uno le hace perder al usuario su posición. El índice de cada valor es su
/// lugar fijo en el `IndexedStack`, ajeno al orden que ve el usuario; todo lo
/// demás se refiere a una pestaña por este id, nunca por su posición visible.
enum NavTabId { home, inbox, add, explore, settings }

const NavTabId kDefaultStartTab = NavTabId.home;

/// Valor guardado de "Última usada" en la pestaña inicial.
const String kStartTabLastUsed = 'last';

/// null si lo guardado no es una pestaña conocida.
NavTabId? parseNavTab(Object? stored) => stored is String ? NavTabId.values.asNameMap()[stored] : null;

/// La pestaña inicial elegida; null es "Última usada". Lo desconocido cae a la
/// predeterminada.
NavTabId? parseStartTab(Object? stored) =>
    stored == kStartTabLastUsed ? null : parseNavTab(stored) ?? kDefaultStartTab;

String serializeStartTab(NavTabId? tab) => tab?.name ?? kStartTabLastUsed;

/// Con qué pestaña abre la app: [startTab] si es fija y, si no, la última usada.
NavTabId resolveInitialTab(NavTabId? startTab, NavTabId? lastTab) => startTab ?? lastTab ?? kDefaultStartTab;

int navBarIndexOf(List<NavTabId> order, NavTabId tab) => order.indexOf(tab);
