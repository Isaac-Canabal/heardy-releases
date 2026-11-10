import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/download_provider.dart';
import '../providers/music_provider.dart';
import '../providers/notifications_provider.dart';
import '../providers/settings_provider.dart';
import '../services/account_prompt.dart';
import '../services/database_helper.dart';
import '../services/desktop_layout.dart';
import '../services/desktop_mini_mode_service.dart';
import '../services/desktop_tray_service.dart';
import '../widgets/desktop_mini_player_view.dart';
import '../theme/app_theme.dart';
import '../theme/area_colors.dart';
import '../widgets/desktop_now_playing_panel.dart';
import '../widgets/desktop_playback_bar.dart';
import '../widgets/desktop_shell_scope.dart';
import '../widgets/max_width_center.dart';
import '../widgets/mini_player.dart';
import '../widgets/server_capacity_gate.dart';
import '../l10n/app_localizations.dart';
import '../models/nav_tab.dart';
import '../models/now_playing_layout.dart';
import '../theme/nav_tabs.dart';
import 'auth/login_screen.dart';
import 'home_screen.dart';
import 'import_screen.dart';
import 'inbox_screen.dart';
import 'playlist_detail_screen.dart';
import 'explore_screen.dart';
import 'settings_screen.dart';

class MainShellScreen extends StatefulWidget {
  const MainShellScreen({super.key});

  @override
  State<MainShellScreen> createState() => _MainShellScreenState();
}

class _MainShellScreenState extends State<MainShellScreen>
    with WidgetsBindingObserver {
  // Un `ValueNotifier` y no un `int` en `setState`: en el escritorio las
  // pestañas viven dentro de la ruta raíz de un `Navigator` anidado, y una
  // ruta ya construida no se reconstruye porque el shell haga `setState`.
  late final ValueNotifier<NavTabId> _tab;
  final GlobalKey<NavigatorState> _contentNav = GlobalKey<NavigatorState>();
  bool _panelOpen = false;
  bool _lyricsExpanded = false;
  bool _cinemaMode = false;

  @override
  void initState() {
    super.initState();
    // `LegalGate` no deja construir el shell hasta que cargan las preferencias.
    _tab = ValueNotifier<NavTabId>(context.read<SettingsProvider>().initialTab);
    WidgetsBinding.instance.addObserver(this);
    // `MainShellScreen` es el único sitio del árbol con un BuildContext real
    // bajo MaterialApp que se construye una sola vez por proceso (main.dart
    // corre fuera del árbol, sin BuildContext ni navigatorKey) — ver
    // CLAUDE.md, Etapa 16 / B2.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _maybeShowAccountPrompt(),
    );
    if (Platform.isWindows) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _initTray());
    }
  }

  Future<void> _initTray() async {
    final l10n = AppLocalizations.of(context)!;
    await DesktopTrayService.instance.init(
      showLabel: l10n.desktopTrayShow,
      quitLabel: l10n.desktopTrayQuit,
    );
  }

  Future<void> _maybeShowAccountPrompt() async {
    final settings = context.read<SettingsProvider>();
    final auth = context.read<HeardyAuthProvider>();
    // Sin esto, `isLoaded` leería siempre el valor por defecto en un
    // callback de una sola pasada — el bug más probable de toda esta función.
    await settings.ensureLoaded();
    if (!mounted) return;

    final songCount = await DatabaseHelper.instance.getLibrarySongCount();
    if (!mounted) return;

    final show = shouldShowAccountPrompt(
      loaded: settings.isLoaded,
      seen: settings.accountPromptSeen,
      // `isSignedIn`, no `isReady`: quien se registró pero no verificó el
      // correo todavía ya aceptó la invitación, y `LoginScreen` se
      // auto-cierra al pasar a `isReady` — un popup compitiendo con esa
      // transición parpadearía.
      signedIn: auth.isSignedIn,
      songCount: songCount,
    );
    if (!show) return;

    final l10n = AppLocalizations.of(context)!;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.accountPromptTitle),
        content: Text(l10n.accountPromptBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.accountPromptNotNow),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const LoginScreen()));
            },
            child: Text(l10n.accountPromptCreateAccount),
          ),
        ],
      ),
    );
    // En TODAS las salidas (la X, tocar afuera, el botón atrás, y los dos
    // botones de arriba) — nunca sólo en "Ahora no".
    if (mounted) await context.read<SettingsProvider>().markAccountPromptSeen();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tab.dispose();
    if (Platform.isWindows) DesktopTrayService.instance.dispose();
    super.dispose();
  }

  void _selectTab(NavTabId tab) {
    // En el escritorio, elegir una sección en la barra lateral también
    // vuelve a la raíz del contenido (si se estaba dentro de una playlist).
    _contentNav.currentState?.popUntil((route) => route.isFirst);
    _tab.value = tab;
    context.read<SettingsProvider>().rememberLastTab(tab);
    setState(() {
      // Con la letra expandida (o en modo cine), el panel ocupa toda la fila
      // y tapa el navegador de contenido (ver _buildDesktopLayout) — sin
      // esto, tocar "Ajustes" u otra sección de la barra lateral no cambiaba
      // nada a la vista porque la letra seguía tapándolo todo.
      _lyricsExpanded = false;
      _cinemaMode = false;
    });
  }

  int _badgeCount(NavTabId tab, int inboxCount, int downloadCount) => switch (tab) {
        NavTabId.inbox => inboxCount,
        NavTabId.add => downloadCount,
        _ => 0,
      };

  void _openPlaylist(String playlistId) {
    final nav = _contentNav.currentState;
    if (nav == null) return;
    nav.popUntil((route) => route.isFirst);
    nav.pushNamed('/playlist', arguments: playlistId);
  }

  void _pushContentRoute(Route<void> route) {
    final nav = _contentNav.currentState;
    if (nav == null) return;
    // Con la letra expandida (o en modo cine) el panel tapa el navegador de
    // contenido: hay que contraerla para que la ruta sea visible.
    if (_lyricsExpanded || _cinemaMode) {
      setState(() {
        _lyricsExpanded = false;
        _cinemaMode = false;
      });
    }
    nav.push(route);
  }

  void _setPanel(bool open) {
    if (_panelOpen == open) return;
    setState(() {
      _panelOpen = open;
      // Sin el panel no hay dónde mostrar la letra expandida ni el modo cine.
      if (!open) {
        _lyricsExpanded = false;
        _cinemaMode = false;
      }
    });
  }

  void _setLyricsExpanded(bool expanded) {
    if (_lyricsExpanded == expanded) return;
    setState(() {
      _lyricsExpanded = expanded;
      // El modo cine sólo tiene sentido con la letra expandida (es el layout
      // que reemplaza) — contraer la letra sin esto dejaba el modo cine
      // "encendido" pero invisible, listo para reaparecer a medias la
      // próxima vez que se expandiera.
      if (!expanded) _cinemaMode = false;
    });
  }

  void _setCinemaMode(bool cinema) {
    if (_cinemaMode == cinema) return;
    setState(() => _cinemaMode = cinema);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // Red de seguridad además del foreground service: si igual se congeló o
    // mató el proceso mientras la app estaba en segundo plano (el service no
    // es garantía absoluta en todos los fabricantes/versiones de Android),
    // volver a primer plano es una señal razonable de "puede que haya que
    // retomar la cola" — igual que ya se hace en el arranque en frío
    // (main.dart), sin necesidad de un polling propio.
    final downloadProvider = context.read<DownloadProvider>();
    downloadProvider.processQueue();
    downloadProvider.retryPendingImports();
    // Estrangulado por dentro (1 h) — ver NotificationsProvider.onAppResumed.
    context.read<NotificationsProvider>().onAppResumed();
  }

  @override
  Widget build(BuildContext context) {
    // Suscribirse a SettingsProvider para redibujar instantáneamente cuando cambie el tema/idioma
    Provider.of<SettingsProvider>(context);
    final inboxCount = context.watch<MusicProvider>().inboxCount;
    // pendingCount ya cuenta el trabajo que se está descargando ahora mismo:
    // sigue en download_queue (la fila SQLite) hasta que termina, y el
    // provider sólo refresca su lista en memoria al principio de cada
    // iteración del bucle — así que sumarle +1 por "current" lo contaría dos
    // veces.
    final downloadCount = context.watch<DownloadProvider>().pendingCount;
    final width = MediaQuery.sizeOf(context).width;

    return ValueListenableBuilder<bool>(
      valueListenable: DesktopMiniModeService.instance.isMini,
      builder: (context, isMini, _) {
        if (isMini) return const DesktopMiniPlayerView();
        return isDesktopLayout(width)
            ? _buildDesktopLayout(context, width, inboxCount, downloadCount)
            : _buildMobileLayout(context, inboxCount, downloadCount);
      },
    );
  }

  /// Tres columnas: barra lateral de navegación + playlists a la izquierda,
  /// el contenido (con su propio `Navigator`, para que abrir una playlist no
  /// tape la barra lateral ni el panel) con la barra de reproducción debajo,
  /// y al lado elegido, cuando está abierto, el panel de "reproduciendo ahora"
  /// a un tercio de la ventana — ver W3 del plan de escritorio.
  Widget _buildDesktopLayout(
    BuildContext context,
    double width,
    int inboxCount,
    int downloadCount,
  ) {
    final spec = desktopLayoutFor(width: width, panelOpen: _panelOpen);
    // El modo cine tapa TODO, barra lateral incluida — es la idea de "sólo
    // letra y carátula" llevada a la ventana entera, no sólo al contenido.
    // Salir sigue siendo posible sin la barra: el botón de modo cine, el de
    // contraer letra, o el de cerrar el panel, todos dentro del propio panel.
    final cinemaFullscreen = _panelOpen && _lyricsExpanded && _cinemaMode;
    return DesktopShellScope(
      panelOpen: _panelOpen,
      openNowPlaying: () => _setPanel(true),
      toggleNowPlaying: () => _setPanel(!_panelOpen),
      openPlaylist: _openPlaylist,
      child: Scaffold(
        body: Container(
          decoration: AppTheme.gradientScaffold(),
          child: Row(
            // `stretch` es lo que le da altura real a las columnas.
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!cinemaFullscreen) ...[
                SizedBox(
                  width: spec.sidebarWidth,
                  child: _DesktopSidebar(
                    order: context.read<SettingsProvider>().navTabOrder,
                    selected: _tab.value,
                    badgeCount: (tab) => _badgeCount(tab, inboxCount, downloadCount),
                    onSelect: _selectTab,
                    onOpenPlaylist: _openPlaylist,
                  ),
                ),
                const VerticalDivider(width: 1, color: Colors.white12),
              ],
              // Con la letra expandida, el panel deja de compartir la fila
              // con el navegador de contenido y la barra de reproducción:
              // se queda con todo el ancho que sobra (letra 2/3 + info 1/3,
              // repartido dentro del propio panel).
              if (_panelOpen && _lyricsExpanded)
                Expanded(
                  child: DesktopNowPlayingPanel(
                    onClose: () => _setPanel(false),
                    onOpenPlaylist: _openPlaylist,
                    onPushContentRoute: _pushContentRoute,
                    lyricsExpanded: true,
                    onToggleLyricsExpanded: () => _setLyricsExpanded(false),
                    cinemaMode: _cinemaMode,
                    onToggleCinemaMode: () => _setCinemaMode(!_cinemaMode),
                  ),
                )
              else
                ...arrangeDesktopColumns<Widget>(
                  context.read<SettingsProvider>().desktopPanelSide,
                  content: Expanded(
                    child: Column(
                      children: [
                        Expanded(child: _buildContentNavigator()),
                        DesktopPlaybackBar(
                          panelOpen: _panelOpen,
                          onTogglePanel: () => _setPanel(!_panelOpen),
                        ),
                      ],
                    ),
                  ),
                  divider: const VerticalDivider(width: 1, color: Colors.white12),
                  panel: _panelOpen
                      ? SizedBox(
                          width: spec.panelWidth,
                          child: DesktopNowPlayingPanel(
                            onClose: () => _setPanel(false),
                            onOpenPlaylist: _openPlaylist,
                            onPushContentRoute: _pushContentRoute,
                            onToggleLyricsExpanded: () => _setLyricsExpanded(true),
                          ),
                        )
                      : null,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContentNavigator() {
    return Navigator(
      key: _contentNav,
      onGenerateRoute: (settings) {
        if (settings.name == '/playlist' && settings.arguments is String) {
          return MaterialPageRoute(
            settings: settings,
            builder: (_) =>
                PlaylistDetailScreen(playlistId: settings.arguments as String),
          );
        }
        return MaterialPageRoute(
          settings: settings,
          builder: (_) => ValueListenableBuilder<NavTabId>(
            valueListenable: _tab,
            builder: (_, tab, __) => _buildTabs(tab),
          ),
        );
      },
    );
  }

  /// El diseño de siempre, el de teléfono: pestañas abajo y contenido
  /// centrado con ancho máximo. Es lo que ve Android, sin cambios.
  Widget _buildMobileLayout(
    BuildContext context,
    int inboxCount,
    int downloadCount,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final order = context.read<SettingsProvider>().navTabOrder;
    final navigationColor = context.select<SettingsProvider, Color?>(
      (s) => s.areaColor(ColorArea.navigation),
    );
    return Scaffold(
      body: Container(
        decoration: AppTheme.gradientScaffold(),
        // Centrado con ancho máximo — la interfaz está pensada para un
        // teléfono (~360-430dp). En una ventana de escritorio angosta, esto
        // la centra en vez de estirarla; en una pantalla de teléfono real el
        // ancho disponible ya es menor que el máximo, así que no cambia nada.
        child: MaxWidthCenter(
          child: Stack(
            children: [
              _buildTabs(_tab.value),
              const Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: MiniPlayer(),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: NavigationBarTheme(
        data: navigationThemeWithOverride(
          NavigationBarTheme.of(context),
          navigationColor,
        ),
        child: MaxWidthCenter(
          stretchHeight: false,
          child: NavigationBar(
            selectedIndex: navBarIndexOf(order, _tab.value),
            onDestinationSelected: (index) => _selectTab(order[index]),
            height: 68,
            destinations: navBarDestinations(
              l10n,
              order,
              badgeCount: (tab) => _badgeCount(tab, inboxCount, downloadCount),
            ),
          ),
        ),
      ),
    );
  }

  /// Las pantallas, compartidas por los dos diseños — un solo
  /// `IndexedStack` para que cambiar de sección (o de diseño al
  /// redimensionar la ventana) no pierda el estado de ninguna.
  Widget _buildTabs(NavTabId current) {
    return ServerCapacityGate(
      child: NavTabStack(
        current: current,
        builder: (tab) => switch (tab) {
          NavTabId.home => const HomeScreen(),
          NavTabId.inbox => const InboxScreen(),
          // No es const (Fase 8: toma un SpotifyService inyectable para tests).
          NavTabId.add => ImportScreen(),
          NavTabId.explore => ExploreScreen(active: current == NavTabId.explore),
          NavTabId.settings => const SettingsScreen(),
        },
      ),
    );
  }
}

/// Barra lateral del diseño de escritorio: las mismas cinco secciones que la
/// barra inferior del teléfono, en vertical, más la lista de playlists
/// siempre a mano (lo que en el teléfono exige entrar a Inicio primero).
class _DesktopSidebar extends StatelessWidget {
  final List<NavTabId> order;
  final NavTabId selected;
  final int Function(NavTabId tab) badgeCount;
  final ValueChanged<NavTabId> onSelect;
  final ValueChanged<String> onOpenPlaylist;

  const _DesktopSidebar({
    required this.order,
    required this.selected,
    required this.badgeCount,
    required this.onSelect,
    required this.onOpenPlaylist,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final playlists = context.watch<MusicProvider>().playlists;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
          child: Row(
            children: [
              Icon(
                Icons.graphic_eq_rounded,
                color: AppTheme.primaryLight,
                size: 22,
              ),
              const SizedBox(width: 10),
              const Text(
                'Heardy',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.3,
                ),
              ),
            ],
          ),
        ),
        for (final tab in order)
          _SidebarItem(
            icon: navTabDef(tab).icon,
            selectedIcon: navTabDef(tab).selectedIcon,
            label: navTabDef(tab).label(l10n),
            badgeCount: badgeCount(tab),
            selected: selected == tab,
            onTap: () => onSelect(tab),
          ),
        const Divider(
          height: 28,
          indent: 20,
          endIndent: 20,
          color: Colors.white12,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Text(
            l10n.homeTitle.toUpperCase(),
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.45),
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
        ),
        Expanded(
          child: playlists.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Text(
                    l10n.homeEmptyTitle,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.35),
                      fontSize: 12,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 12),
                  itemCount: playlists.length,
                  itemBuilder: (context, index) {
                    final playlist = playlists[index];
                    return ListTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      leading: Icon(
                        Icons.queue_music_rounded,
                        size: 18,
                        color: Colors.white.withValues(alpha: 0.5),
                      ),
                      title: Text(
                        playlist.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.8),
                          fontSize: 13,
                        ),
                      ),
                      onTap: () => onOpenPlaylist(playlist.id),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _SidebarItem extends StatelessWidget {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final int badgeCount;
  final bool selected;
  final VoidCallback onTap;

  const _SidebarItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.badgeCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected
        ? resolveAreaColor(
            context.select<SettingsProvider, Color?>(
              (s) => s.areaColor(ColorArea.navigation),
            ),
            AppTheme.primaryLight,
          )
        : Colors.white.withValues(alpha: 0.75);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Material(
        color: selected
            ? Colors.white.withValues(alpha: 0.07)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(
              children: [
                Badge(
                  isLabelVisible: badgeCount > 0,
                  label: Text('$badgeCount'),
                  child: Icon(
                    selected ? selectedIcon : icon,
                    size: 20,
                    color: color,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: color,
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
