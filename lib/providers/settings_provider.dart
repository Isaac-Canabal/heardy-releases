import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/nav_tab.dart';
import '../models/now_playing_layout.dart';
import '../services/explore_logic.dart';
import '../services/official_server.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_fonts.dart';
import '../theme/area_colors.dart';

enum AppThemePreset { navy, violet, rose, green, orange, red, custom }

enum AppLanguage { es, en }

/// Secciones de Ajustes en su orden predeterminado. Los nombres se guardan en
/// preferencias: renombrar uno le hace perder al usuario su posición.
enum SettingsSectionId {
  account,
  folderSync,
  lanSync,
  ignoredRecommendations,
  statistics,
  storage,
  appearance,
  language,
  playlistOrder,
  localLibrary,
  audio,
  search,
  support,
  about,
}

/// Orden efectivo de [known] (los nombres en su orden predeterminado) a partir
/// de lo guardado, que puede venir de otra versión o estar corrupto: se quitan
/// duplicados y nombres desconocidos, y una sección ausente se coloca justo
/// tras la que la precede por defecto, para que ninguna se pierda nunca.
List<String> resolveSectionOrder(Object? stored, List<String> known) {
  final order = <String>[];
  if (stored is List) {
    for (final name in stored) {
      if (name is String && known.contains(name) && !order.contains(name)) order.add(name);
    }
  }
  if (order.isEmpty) return [...known];
  for (final (index, name) in known.indexed) {
    if (order.contains(name)) continue;
    order.insert(index == 0 ? 0 : order.indexOf(known[index - 1]) + 1, name);
  }
  return order;
}

/// [resolveSectionOrder] para un enum: [defaults] es su orden predeterminado.
List<T> resolveEnumOrder<T extends Enum>(Object? stored, List<T> defaults) {
  final byName = defaults.asNameMap();
  return List.unmodifiable(
    resolveSectionOrder(stored, [for (final value in defaults) value.name]).map((name) => byName[name]!),
  );
}

class SettingsProvider with ChangeNotifier {
  static const _presetKey = 'theme_preset';
  static const _maxResultsKey = 'max_search_results';
  static const _languageKey = 'app_language';

  /// Restos de cuando la dirección del servidor se editaba a mano en Ajustes.
  /// Se borran al cargar (ver [_load]) en vez de simplemente ignorarse: sin UI
  /// que los edite, un valor viejo apuntando a un servidor que ya no existe
  /// dejaría la app sin descargas para siempre y sin forma de arreglarlo
  /// desde dentro.
  static const _legacyServerUrlKey = 'download_server_url';
  static const _legacyServerKeyKey = 'download_server_api_key';
  static const _customPrimaryKey = 'custom_theme_primary';
  static const _customSecondaryKey = 'custom_theme_secondary';
  static const _customCombinedKey = 'custom_theme_combined';
  static const _accountPromptSeenKey = 'account_prompt_seen';
  static const _shareNowPlayingKey = 'share_now_playing';
  static const _dynamicNowPlayingColorKey = 'dynamic_now_playing_color';
  static const skipSilenceKey = 'skip_silence';
  static const trackFadeKey = 'track_fade';
  static const _legalAcceptedVersionKey = 'legal_accepted_version';
  static const _legalAcceptedAtKey = 'legal_accepted_at';
  static const _exploreHiddenKey = 'explore_hidden_shelves';
  static const _exploreCountryKey = 'explore_country';
  static const _areaColorsKey = 'area_colors';
  static const appFontKey = 'app_font';
  static const textScaleKey = 'app_text_scale';
  static const lyricsTextScaleKey = 'lyrics_text_scale';
  static const settingsSectionOrderKey = 'settings_section_order';
  static const exploreShelfOrderKey = 'explore_shelf_order';
  static const navTabOrderKey = 'nav_tab_order';
  static const startTabKey = 'start_tab';
  static const lastTabKey = 'last_tab';
  static const nowPlayingTitleAlignKey = 'now_playing_title_align';
  static const nowPlayingArtSizeKey = 'now_playing_art_size';
  static const showSeekButtonsKey = 'now_playing_seek_buttons';
  static const nowPlayingBlockOrderKey = 'now_playing_block_order';
  static const desktopPanelSideKey = 'desktop_panel_side';

  AppThemePreset _preset = AppThemePreset.navy;
  bool _loaded = false;
  int _maxSearchResults = 20;
  AppLanguage _language = AppLanguage.es;

  // Colores del modo "Personalizado" (AppThemePreset.custom). Persistidos
  // aparte del preset en sí, para que elegir otro preset y volver a
  // "Personalizado" no pierda lo elegido. Nunca se usan para dibujar nada
  // salvo cuando _preset == custom (ver AppTheme._p).
  Color _customPrimary = const Color(0xFF2563EB);
  Color _customSecondary = const Color(0xFF38BDF8);
  bool _customCombined = true;
  bool _accountPromptSeen = false;
  bool _shareNowPlaying = false;
  bool _dynamicNowPlayingColor = true;
  bool _skipSilence = false;
  bool _trackFade = false;
  String? _legalAcceptedVersion;
  Set<ExploreShelfId> _exploreHidden = {};
  String? _exploreCountry;
  Map<ColorArea, Color> _areaColors = {};
  bool _areaColorsSaving = false;
  bool _areaColorsDirty = false;
  AppFont _appFont = AppFont.system;
  AppTextScale _textScale = AppTextScale.normal;
  AppTextScale _lyricsTextScale = AppTextScale.normal;
  List<SettingsSectionId> _settingsSectionOrder = SettingsSectionId.values;
  List<ExploreShelfId> _exploreShelfOrder = kDefaultExploreShelfOrder;
  List<NavTabId> _navTabOrder = NavTabId.values;
  NavTabId? _startTab = kDefaultStartTab;
  NavTabId? _lastTab;
  NowPlayingTitleAlign _nowPlayingTitleAlign = NowPlayingTitleAlign.center;
  NowPlayingArtSize _nowPlayingArtSize = NowPlayingArtSize.medium;
  bool _showSeekButtons = true;
  List<NowPlayingBlock> _nowPlayingBlockOrder = NowPlayingBlock.values;
  DesktopPanelSide _desktopPanelSide = DesktopPanelSide.right;

  AppThemePreset get preset => _preset;
  bool get isLoaded => _loaded;
  int get maxSearchResults => _maxSearchResults;
  AppLanguage get language => _language;
  Locale get locale => Locale(_language.name);
  Color get customPrimary => _customPrimary;
  Color get customSecondary => _customSecondary;
  bool get customCombined => _customCombined;
  bool get accountPromptSeen => _accountPromptSeen;
  bool get shareNowPlaying => _shareNowPlaying;
  bool get dynamicNowPlayingColor => _dynamicNowPlayingColor;
  bool get skipSilence => _skipSilence;
  bool get trackFade => _trackFade;

  /// Secciones de Explorar que el usuario ocultó; no se piden al servidor.
  Set<ExploreShelfId> get exploreHiddenShelves => Set.unmodifiable(_exploreHidden);

  /// País elegido para las listas regionales de Explorar; null = el del dispositivo.
  String? get exploreCountry => _exploreCountry;

  /// Colores elegidos por zona. Una zona ausente sigue el tema.
  Map<ColorArea, Color> get areaColors => Map.unmodifiable(_areaColors);
  Color? areaColor(ColorArea area) => _areaColors[area];

  AppFont get appFont => _appFont;
  AppTextScale get textScale => _textScale;

  /// Aparte de [textScale]: sólo la vista de letras de canciones.
  AppTextScale get lyricsTextScale => _lyricsTextScale;

  List<SettingsSectionId> get settingsSectionOrder => _settingsSectionOrder;

  /// Orden visual de Explorar: incluye las ocultas y no influye en qué se pide
  /// a la red.
  List<ExploreShelfId> get exploreShelfOrder => _exploreShelfOrder;

  List<NavTabId> get navTabOrder => _navTabOrder;

  /// null es "Última usada".
  NavTabId? get startTab => _startTab;

  /// Con qué pestaña abre la app.
  NavTabId get initialTab => resolveInitialTab(_startTab, _lastTab);

  NowPlayingTitleAlign get nowPlayingTitleAlign => _nowPlayingTitleAlign;
  NowPlayingArtSize get nowPlayingArtSize => _nowPlayingArtSize;
  bool get showSeekButtons => _showSeekButtons;
  List<NowPlayingBlock> get nowPlayingBlockOrder => _nowPlayingBlockOrder;
  DesktopPanelSide get desktopPanelSide => _desktopPanelSide;

  bool get nowPlayingLayoutIsDefault =>
      _nowPlayingTitleAlign == NowPlayingTitleAlign.center &&
      _nowPlayingArtSize == NowPlayingArtSize.medium &&
      _showSeekButtons &&
      listEquals(_nowPlayingBlockOrder, NowPlayingBlock.values) &&
      _desktopPanelSide == DesktopPanelSide.right;

  /// Versión de los textos legales que el usuario aceptó en esta instalación;
  /// `null` si nunca. Ver legal_texts.dart.
  String? get legalAcceptedVersion => _legalAcceptedVersion;

  /// Dirección del microservidor de descargas (`server/` en este repo).
  /// **Fija, compilada en el binario** (ver [OfficialServer]): ya no se
  /// configura desde la app. La autenticación ya no vive acá — desde la Fase
  /// 2 del plan de seguridad es un token de Firebase (ver [HeardyAuthProvider]),
  /// no una clave fija que este provider pudiera exponer.
  ///
  /// El servidor oficial es uno solo y estable, así que dejar la dirección
  /// editable sólo servía para que el usuario se rompiera las descargas él
  /// mismo y no supiera volver. Apuntar a otro servidor sigue siendo posible
  /// con `--dart-define=HEARDY_OFFICIAL_SERVER_URL=...`, que es donde
  /// corresponde: en tiempo de build, no en tiempo de ejecución.
  ///
  /// Sigue siendo un getter de este provider (y no una lectura directa de
  /// [OfficialServer]) para no tocar los llamadores: `main.dart` se lo pasa a
  /// `YtdlpServerSource` como callback, e `import_screen`/`search_screen`
  /// consultan [hasDownloadServer].
  String get downloadServerUrl => OfficialServer.url;
  bool get hasDownloadServer => OfficialServer.url.trim().isNotEmpty;

  /// Guardado en un campo (no re-invocado) para que [ensureLoaded] pueda
  /// esperar la MISMA carga que ya disparó el constructor — un callback de
  /// una sola pasada (el popup de vinculación de cuenta) no puede sondear
  /// [isLoaded] sin inventar un bucle de polling.
  late final Future<void> _loadFuture = _load();

  SettingsProvider() {
    // Fuerza la creación del Future de arriba sin duplicar la carga: un
    // campo `late final` con inicializador se dispara solo en su primer
    // acceso, y este es ese primer acceso. `.ignore()` es la forma explícita
    // de "no me interesa esperarlo acá" (ensureLoaded() sí lo espera).
    _loadFuture.ignore();
  }

  /// Espera a que termine la carga inicial desde SharedPreferences. Sin
  /// esto, un callback de una sola pasada (ver `shouldShowAccountPrompt`)
  /// leería siempre el valor por defecto de [accountPromptSeen] (false) y el
  /// popup reaparecería en cada arranque — el bug más probable de toda esta
  /// función.
  Future<void> ensureLoaded() => _loadFuture;

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final index = prefs.getInt(_presetKey);
    if (index != null && index >= 0 && index < AppThemePreset.values.length) {
      _preset = AppThemePreset.values[index];
    }
    _maxSearchResults = prefs.getInt(_maxResultsKey) ?? 20;
    final langIndex = prefs.getInt(_languageKey);
    if (langIndex != null && langIndex >= 0 && langIndex < AppLanguage.values.length) {
      _language = AppLanguage.values[langIndex];
    }
    // Ver [_legacyServerUrlKey]: se borra, no se ignora, para que un servidor
    // propio configurado en una versión anterior no sobreviva sin UI que lo
    // pueda deshacer.
    await prefs.remove(_legacyServerUrlKey);
    await prefs.remove(_legacyServerKeyKey);
    final customPrimaryArgb = prefs.getInt(_customPrimaryKey);
    if (customPrimaryArgb != null) _customPrimary = Color(customPrimaryArgb);
    final customSecondaryArgb = prefs.getInt(_customSecondaryKey);
    if (customSecondaryArgb != null) _customSecondary = Color(customSecondaryArgb);
    _customCombined = prefs.getBool(_customCombinedKey) ?? true;
    _accountPromptSeen = prefs.getBool(_accountPromptSeenKey) ?? false;
    _shareNowPlaying = prefs.getBool(_shareNowPlayingKey) ?? false;
    _dynamicNowPlayingColor = prefs.getBool(_dynamicNowPlayingColorKey) ?? true;
    _skipSilence = prefs.getBool(skipSilenceKey) ?? false;
    _trackFade = prefs.getBool(trackFadeKey) ?? false;
    _legalAcceptedVersion = prefs.getString(_legalAcceptedVersionKey);
    _exploreHidden = parseHiddenShelves(prefs.getStringList(_exploreHiddenKey));
    _exploreCountry = normalizeExploreCountry(prefs.getString(_exploreCountryKey));
    _areaColors = parseAreaColors(prefs.getString(_areaColorsKey));
    _appFont = parseAppFont(prefs.getString(appFontKey));
    _textScale = parseAppTextScale(prefs.getString(textScaleKey));
    _lyricsTextScale = parseAppTextScale(prefs.getString(lyricsTextScaleKey));
    // `get`, no `getStringList`: un valor de otro tipo lanzaría y dejaría la
    // carga a medias.
    _settingsSectionOrder = resolveEnumOrder(prefs.get(settingsSectionOrderKey), SettingsSectionId.values);
    _exploreShelfOrder = resolveEnumOrder(prefs.get(exploreShelfOrderKey), kDefaultExploreShelfOrder);
    _navTabOrder = resolveEnumOrder(prefs.get(navTabOrderKey), NavTabId.values);
    _startTab = parseStartTab(prefs.get(startTabKey));
    _lastTab = parseNavTab(prefs.get(lastTabKey));
    _nowPlayingTitleAlign = parseStoredEnum(
      prefs.get(nowPlayingTitleAlignKey),
      NowPlayingTitleAlign.values,
      NowPlayingTitleAlign.center,
    );
    _nowPlayingArtSize = parseStoredEnum(
      prefs.get(nowPlayingArtSizeKey),
      NowPlayingArtSize.values,
      NowPlayingArtSize.medium,
    );
    _showSeekButtons = parseStoredBool(prefs.get(showSeekButtonsKey), fallback: true);
    _nowPlayingBlockOrder = resolveEnumOrder(prefs.get(nowPlayingBlockOrderKey), NowPlayingBlock.values);
    _desktopPanelSide = parseStoredEnum(
      prefs.get(desktopPanelSideKey),
      DesktopPanelSide.values,
      DesktopPanelSide.right,
    );
    _loaded = true;
    notifyListeners();
  }

  /// Se pone en TODAS las salidas del popup (la X, tocar afuera, el botón
  /// atrás, y los dos botones) — nunca sólo en "Ahora no". Registra
  /// "preguntamos", no "comprobamos": una instalación nueva sin canciones
  /// nunca llega a llamar esto, así que ver 0 canciones y luego importar 40
  /// archivos sigue mostrando la invitación una vez.
  Future<void> markAccountPromptSeen() async {
    _accountPromptSeen = true;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_accountPromptSeenKey, true);
  }

  Future<void> acceptLegal(String version) async {
    _legalAcceptedVersion = version;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_legalAcceptedVersionKey, version);
    await prefs.setString(_legalAcceptedAtKey, DateTime.now().toIso8601String());
  }

  Future<void> setExploreShelfHidden(ExploreShelfId id, bool hidden) async {
    final next = {..._exploreHidden};
    if (hidden ? !next.add(id) : !next.remove(id)) return;
    await _saveExploreHidden(next);
  }

  Future<void> showAllExploreShelves() => _saveExploreHidden({});

  Future<void> _saveExploreHidden(Set<ExploreShelfId> hidden) async {
    _exploreHidden = hidden;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_exploreHiddenKey, serializeHiddenShelves(hidden));
  }

  Future<void> setExploreCountry(String? code) async {
    _exploreCountry = normalizeExploreCountry(code);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    final c = _exploreCountry;
    if (c == null) {
      await prefs.remove(_exploreCountryKey);
    } else {
      await prefs.setString(_exploreCountryKey, c);
    }
  }

  Future<void> setAppFont(AppFont font) async {
    _appFont = font;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(appFontKey, font.name);
  }

  Future<void> setTextScale(AppTextScale scale) async {
    _textScale = scale;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(textScaleKey, scale.name);
  }

  Future<void> setLyricsTextScale(AppTextScale scale) async {
    _lyricsTextScale = scale;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(lyricsTextScaleKey, scale.name);
  }

  Future<void> setSettingsSectionOrder(List<SettingsSectionId> order) async {
    _settingsSectionOrder = resolveEnumOrder([for (final id in order) id.name], SettingsSectionId.values);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      settingsSectionOrderKey,
      [for (final id in _settingsSectionOrder) id.name],
    );
  }

  Future<void> setExploreShelfOrder(List<ExploreShelfId> order) async {
    _exploreShelfOrder = resolveEnumOrder([for (final id in order) id.name], kDefaultExploreShelfOrder);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(exploreShelfOrderKey, [for (final id in _exploreShelfOrder) id.name]);
  }

  Future<void> setNavTabOrder(List<NavTabId> order) async {
    _navTabOrder = resolveEnumOrder([for (final id in order) id.name], NavTabId.values);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(navTabOrderKey, [for (final id in _navTabOrder) id.name]);
  }

  /// [tab] null es "Última usada".
  Future<void> setStartTab(NavTabId? tab) async {
    _startTab = tab;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(startTabKey, serializeStartTab(tab));
  }

  /// Se guarda siempre, aunque la pestaña inicial sea fija, para que elegir
  /// "Última usada" funcione desde el primer arranque. Sin aviso: no cambia
  /// nada en pantalla.
  Future<void> rememberLastTab(NavTabId tab) async {
    if (_lastTab == tab) return;
    _lastTab = tab;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(lastTabKey, tab.name);
  }

  Future<void> setNowPlayingTitleAlign(NowPlayingTitleAlign align) async {
    _nowPlayingTitleAlign = align;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(nowPlayingTitleAlignKey, align.name);
  }

  Future<void> setNowPlayingArtSize(NowPlayingArtSize size) async {
    _nowPlayingArtSize = size;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(nowPlayingArtSizeKey, size.name);
  }

  Future<void> setShowSeekButtons(bool show) async {
    _showSeekButtons = show;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(showSeekButtonsKey, show);
  }

  Future<void> setNowPlayingBlockOrder(List<NowPlayingBlock> order) async {
    _nowPlayingBlockOrder = resolveEnumOrder([for (final block in order) block.name], NowPlayingBlock.values);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(nowPlayingBlockOrderKey, [for (final block in _nowPlayingBlockOrder) block.name]);
  }

  Future<void> setDesktopPanelSide(DesktopPanelSide side) async {
    _desktopPanelSide = side;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(desktopPanelSideKey, side.name);
  }

  Future<void> resetNowPlayingLayout() async {
    _nowPlayingTitleAlign = NowPlayingTitleAlign.center;
    _nowPlayingArtSize = NowPlayingArtSize.medium;
    _showSeekButtons = true;
    _nowPlayingBlockOrder = NowPlayingBlock.values;
    _desktopPanelSide = DesktopPanelSide.right;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(nowPlayingTitleAlignKey);
    await prefs.remove(nowPlayingArtSizeKey);
    await prefs.remove(showSeekButtonsKey);
    await prefs.remove(nowPlayingBlockOrderKey);
    await prefs.remove(desktopPanelSideKey);
  }

  /// `null` devuelve la zona al tema. Se llama en cada paso del arrastre del
  /// selector, así que la pantalla cambia al instante y el disco no se satura.
  Future<void> setAreaColor(ColorArea area, Color? color) async {
    final argb = color == null ? null : color.toARGB32() | 0xFF000000;
    if (argb == _areaColors[area]?.toARGB32()) return;
    _areaColors = {..._areaColors};
    if (argb == null) {
      _areaColors.remove(area);
    } else {
      _areaColors[area] = Color(argb);
    }
    notifyListeners();
    await _saveAreaColors();
  }

  Future<void> resetAreaColors() async {
    if (_areaColors.isEmpty) return;
    _areaColors = {};
    notifyListeners();
    await _saveAreaColors();
  }

  /// Una sola escritura a la vez, y al terminar se repite si hubo cambios: dos
  /// escrituras simultáneas podrían dejar en disco la más vieja.
  Future<void> _saveAreaColors() async {
    _areaColorsDirty = true;
    if (_areaColorsSaving) return;
    _areaColorsSaving = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      while (_areaColorsDirty) {
        _areaColorsDirty = false;
        if (_areaColors.isEmpty) {
          await prefs.remove(_areaColorsKey);
        } else {
          await prefs.setString(_areaColorsKey, serializeAreaColors(_areaColors));
        }
      }
    } finally {
      _areaColorsSaving = false;
    }
  }

  Future<void> setShareNowPlaying(bool enabled) async {
    _shareNowPlaying = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_shareNowPlayingKey, enabled);
  }

  Future<void> setDynamicNowPlayingColor(bool enabled) async {
    _dynamicNowPlayingColor = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_dynamicNowPlayingColorKey, enabled);
  }

  Future<void> setSkipSilence(bool enabled) async {
    _skipSilence = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(skipSilenceKey, enabled);
  }

  Future<void> setTrackFade(bool enabled) async {
    _trackFade = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(trackFadeKey, enabled);
  }

  Future<void> setPreset(AppThemePreset preset) async {
    _preset = preset;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_presetKey, preset.index);
  }

  Future<void> setMaxSearchResults(int value) async {
    if (value >= 10 && value <= 200) {
      _maxSearchResults = value;
      notifyListeners();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_maxResultsKey, value);
    }
  }

  String presetLabel(BuildContext context, AppThemePreset p) {
    final l10n = AppLocalizations.of(context)!;
    return switch (p) {
      AppThemePreset.navy => l10n.themeNavy,
      AppThemePreset.violet => l10n.themeViolet,
      AppThemePreset.rose => l10n.themeRose,
      AppThemePreset.green => l10n.themeGreen,
      AppThemePreset.orange => l10n.themeOrange,
      AppThemePreset.red => l10n.themeRed,
      AppThemePreset.custom => l10n.themeCustom,
    };
  }

  /// Guarda los colores del modo "Personalizado" y lo activa como preset
  /// actual en un solo paso — separarlos obligaría a la UI a llamar a
  /// [setPreset] aparte y arriesgar un frame con colores nuevos pero preset
  /// viejo (o viceversa).
  Future<void> setCustomColors({
    required Color primary,
    required Color secondary,
    required bool combined,
  }) async {
    _customPrimary = primary;
    _customSecondary = secondary;
    _customCombined = combined;
    _preset = AppThemePreset.custom;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_customPrimaryKey, primary.toARGB32());
    await prefs.setInt(_customSecondaryKey, secondary.toARGB32());
    await prefs.setBool(_customCombinedKey, combined);
    await prefs.setInt(_presetKey, AppThemePreset.custom.index);
  }

  Future<void> setLanguage(AppLanguage language) async {
    _language = language;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_languageKey, language.index);
  }

  String languageLabel(AppLanguage l) => switch (l) {
    AppLanguage.es => 'Español',
    AppLanguage.en => 'English',
  };
}
