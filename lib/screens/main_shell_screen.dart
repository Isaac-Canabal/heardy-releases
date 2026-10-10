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
import '../widgets/desktop_now_playing_panel.dart';
import '../widgets/desktop_playback_bar.dart';
import '../widgets/desktop_shell_scope.dart';
import '../widgets/max_width_center.dart';
import '../widgets/mini_player.dart';
import '../widgets/server_capacity_gate.dart';
import '../l10n/app_localizations.dart';
import 'auth/login_screen.dart';
import 'home_screen.dart';
import 'import_screen.dart';
import 'inbox_screen.dart';
import 'playlist_detail_screen.dart';
import 'explore_screen.dart';
import 'settings_screen.dart';

/// Posición de Explorar en las pestañas (y en la barra lateral de escritorio).
/// Ocupa el hueco que tenía Buscar: la búsqueda ahora es una ruta que se abre
/// desde Explorar.
const int _exploreTab = 3;

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
  final ValueNotifier<int> _tab = ValueNotifier<int>(0);
  final GlobalKey<NavigatorState> _contentNav = GlobalKey<NavigatorState>();
  bool _panelOpen = false;
  bool _lyricsExpanded = false;
  bool _cinemaMode = false;

  @override
  void initState() {
    super.initState();
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

  void _selectTab(int i) {
    // En el escritorio, elegir una sección en la barra lateral también
    // vuelve a la raíz del contenido (si se estaba dentro de una playlist).
    _contentNav.currentState?.popUntil((route) => route.isFirst);
    _tab.value = i;
    setState(() {
      // Con la letra expandida (o en modo cine), el panel ocupa toda la fila
      // y tapa el navegador de contenido (ver _buildDesktopLayout) — sin
      // esto, tocar "Ajustes" u otra sección de la barra lateral no cambiaba
      // nada a la vista porque la letra seguía tapándolo todo.
      _lyricsExpanded = false;
      _cinemaMode = false;
    });
  }

  void _openPlaylist(String playlistId) {
    final nav = _contentNav.currentState;
    if (nav == null) return;
    nav.popUntil((route) => route.isFirst);
    nav.pushNamed('/playlist', arguments: playlistId);
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
  /// y a la derecha, cuando está abierto, el panel de "reproduciendo ahora"
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
                    selectedIndex: _tab.value,
                    inboxCount: inboxCount,
                    downloadCount: downloadCount,
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
                    lyricsExpanded: true,
                    onToggleLyricsExpanded: () => _setLyricsExpanded(false),
                    cinemaMode: _cinemaMode,
                    onToggleCinemaMode: () => _setCinemaMode(!_cinemaMode),
                  ),
                )
              else ...[
                Expanded(
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
                if (_panelOpen) ...[
                  const VerticalDivider(width: 1, color: Colors.white12),
                  SizedBox(
                    width: spec.panelWidth,
                    child: DesktopNowPlayingPanel(
                      onClose: () => _setPanel(false),
                      onOpenPlaylist: _openPlaylist,
                      onToggleLyricsExpanded: () => _setLyricsExpanded(true),
                    ),
                  ),
                ],
              ],
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
          builder: (_) => ValueListenableBuilder<int>(
            valueListenable: _tab,
            builder: (_, index, __) => _buildTabs(index),
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
      bottomNavigationBar: MaxWidthCenter(
        stretchHeight: false,
        child: NavigationBar(
          selectedIndex: _tab.value,
          onDestinationSelected: _selectTab,
          height: 68,
          destinations: [
            NavigationDestination(
              icon: const Icon(Icons.library_music_outlined),
              selectedIcon: const Icon(Icons.library_music_rounded),
              label: l10n.homeTitle,
            ),
            NavigationDestination(
              icon: Badge(
                isLabelVisible: inboxCount > 0,
                label: Text('$inboxCount'),
                child: const Icon(Icons.inbox_outlined),
              ),
              selectedIcon: Badge(
                isLabelVisible: inboxCount > 0,
                label: Text('$inboxCount'),
                child: const Icon(Icons.inbox_rounded),
              ),
              label: l10n.navInbox,
            ),
            NavigationDestination(
              icon: Badge(
                isLabelVisible: downloadCount > 0,
                label: Text('$downloadCount'),
                child: const Icon(Icons.cloud_download_outlined),
              ),
              selectedIcon: Badge(
                isLabelVisible: downloadCount > 0,
                label: Text('$downloadCount'),
                child: const Icon(Icons.cloud_download_rounded),
              ),
              label: l10n.navAdd,
            ),
            NavigationDestination(
              icon: const Icon(Icons.explore_outlined),
              selectedIcon: const Icon(Icons.explore_rounded),
              label: l10n.exploreTitle,
            ),
            NavigationDestination(
              icon: const Icon(Icons.settings_outlined),
              selectedIcon: const Icon(Icons.settings_rounded),
              label: l10n.settingsTitle,
            ),
          ],
        ),
      ),
    );
  }

  /// Las cinco pantallas, compartidas por los dos diseños — un solo
  /// `IndexedStack` para que cambiar de sección (o de diseño al
  /// redimensionar la ventana) no pierda el estado de ninguna.
  Widget _buildTabs(int index) {
    return ServerCapacityGate(child: _buildTabStack(index));
  }

  Widget _buildTabStack(int index) {
    return IndexedStack(
      index: index,
      // ImportScreen ya no es const (Fase 8: toma un SpotifyService
      // inyectable para tests), así que la lista entera deja de serlo.
      children: [
        const HomeScreen(),
        const InboxScreen(),
        ImportScreen(),
        ExploreScreen(active: index == _exploreTab),
        const SettingsScreen(),
      ],
    );
  }
}

/// Barra lateral del diseño de escritorio: las mismas cinco secciones que la
/// barra inferior del teléfono, en vertical, más la lista de playlists
/// siempre a mano (lo que en el teléfono exige entrar a Inicio primero).
class _DesktopSidebar extends StatelessWidget {
  final int selectedIndex;
  final int inboxCount;
  final int downloadCount;
  final ValueChanged<int> onSelect;
  final ValueChanged<String> onOpenPlaylist;

  const _DesktopSidebar({
    required this.selectedIndex,
    required this.inboxCount,
    required this.downloadCount,
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
        _SidebarItem(
          icon: Icons.library_music_outlined,
          selectedIcon: Icons.library_music_rounded,
          label: l10n.homeTitle,
          selected: selectedIndex == 0,
          onTap: () => onSelect(0),
        ),
        _SidebarItem(
          icon: Icons.inbox_outlined,
          selectedIcon: Icons.inbox_rounded,
          label: l10n.navInbox,
          badgeCount: inboxCount,
          selected: selectedIndex == 1,
          onTap: () => onSelect(1),
        ),
        _SidebarItem(
          icon: Icons.cloud_download_outlined,
          selectedIcon: Icons.cloud_download_rounded,
          label: l10n.navAdd,
          badgeCount: downloadCount,
          selected: selectedIndex == 2,
          onTap: () => onSelect(2),
        ),
        _SidebarItem(
          icon: Icons.explore_outlined,
          selectedIcon: Icons.explore_rounded,
          label: l10n.exploreTitle,
          selected: selectedIndex == _exploreTab,
          onTap: () => onSelect(_exploreTab),
        ),
        _SidebarItem(
          icon: Icons.settings_outlined,
          selectedIcon: Icons.settings_rounded,
          label: l10n.settingsTitle,
          selected: selectedIndex == 4,
          onTap: () => onSelect(4),
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
        ? AppTheme.primaryLight
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
