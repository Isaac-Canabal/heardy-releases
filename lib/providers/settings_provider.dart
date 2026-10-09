import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/official_server.dart';
import '../l10n/app_localizations.dart';

enum AppThemePreset { navy, violet, rose, green, orange, red, custom }

enum AppLanguage { es, en }

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
  static const _legalAcceptedVersionKey = 'legal_accepted_version';
  static const _legalAcceptedAtKey = 'legal_accepted_at';

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
  String? _legalAcceptedVersion;

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
    _legalAcceptedVersion = prefs.getString(_legalAcceptedVersionKey);
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

  Future<void> setShareNowPlaying(bool enabled) async {
    _shareNowPlaying = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_shareNowPlayingKey, enabled);
  }

  Future<void> setPreset(AppThemePreset preset) async {
    _preset = preset;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_presetKey, preset.index);
  }

  Future<void> setMaxSearchResults(int value) async {
    if (value >= 10 && value <= 100) {
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
