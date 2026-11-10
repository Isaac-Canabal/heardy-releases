part of 'settings_screen.dart';

const _sectionIcons = {
  SettingsSectionId.account: Icons.person_outline_rounded,
  SettingsSectionId.folderSync: Icons.folder_copy_outlined,
  SettingsSectionId.lanSync: Icons.wifi_tethering_rounded,
  SettingsSectionId.ignoredRecommendations: Icons.visibility_off_outlined,
  SettingsSectionId.statistics: Icons.bar_chart_rounded,
  SettingsSectionId.storage: Icons.storage_rounded,
  SettingsSectionId.appearance: Icons.palette_outlined,
  SettingsSectionId.language: Icons.language_rounded,
  SettingsSectionId.playlistOrder: Icons.queue_music_rounded,
  SettingsSectionId.localLibrary: Icons.folder_open_rounded,
  SettingsSectionId.audio: Icons.graphic_eq_rounded,
  SettingsSectionId.search: Icons.search_rounded,
  SettingsSectionId.support: Icons.favorite_border_rounded,
  SettingsSectionId.about: Icons.info_outline_rounded,
};

String _sectionLabel(AppLocalizations l10n, SettingsSectionId id) => switch (id) {
      SettingsSectionId.account => l10n.settingsAccountSectionTitle,
      SettingsSectionId.folderSync => l10n.folderSyncSectionTitle,
      SettingsSectionId.lanSync => l10n.lanSyncSectionTitle,
      SettingsSectionId.ignoredRecommendations => l10n.ignoredRecsSectionTitle,
      SettingsSectionId.statistics => l10n.statsSectionTitle,
      SettingsSectionId.storage => l10n.settingsSectionStorage,
      SettingsSectionId.appearance => l10n.settingsSectionAppearance,
      SettingsSectionId.language => l10n.settingsSectionLanguage,
      SettingsSectionId.playlistOrder => l10n.settingsSectionPlaylistOrder,
      SettingsSectionId.localLibrary => l10n.settingsSectionLocalLibrary,
      SettingsSectionId.audio => l10n.settingsSectionAudio,
      SettingsSectionId.search => l10n.settingsSectionSearch,
      SettingsSectionId.support => l10n.supportSectionTitle,
      SettingsSectionId.about => l10n.settingsSectionAbout,
    };

Widget _sectionBody(SettingsSectionId id) => switch (id) {
      SettingsSectionId.account => const _AccountSection(),
      SettingsSectionId.folderSync => const _FolderSyncSection(),
      SettingsSectionId.lanSync => const LanSyncSettingsSection(),
      SettingsSectionId.ignoredRecommendations => const _IgnoredRecommendationsSection(),
      SettingsSectionId.statistics => const _StatisticsSection(),
      SettingsSectionId.storage => const _StorageSection(),
      SettingsSectionId.appearance => const _AppearanceSection(),
      SettingsSectionId.language => const _LanguageSection(),
      SettingsSectionId.playlistOrder => const _PlaylistOrderSection(),
      SettingsSectionId.localLibrary => const _LocalLibrarySection(),
      SettingsSectionId.audio => const _AudioEffectsSection(),
      SettingsSectionId.search => const _SearchSection(),
      SettingsSectionId.support => const _SupportCard(),
      SettingsSectionId.about => const _AboutSection(),
    };

/// Lista plana, no una `Column` por sección: los hijos de `ListView` conservan
/// el ancho completo sin depender de cómo se alinee cada sección. La clave
/// mantiene el estado de la sección al moverla. Estadísticas dibuja su título.
List<Widget> _sectionChildren(AppLocalizations l10n, SettingsSectionId id) => [
      if (id != SettingsSectionId.statistics) ...[
        _SectionTitle(_sectionLabel(l10n, id)),
        const SizedBox(height: 10),
      ],
      KeyedSubtree(key: ValueKey(id), child: _sectionBody(id)),
    ];

Future<void> _showSectionOrderSheet(BuildContext context) {
  final l10n = AppLocalizations.of(context)!;
  final settings = context.read<SettingsProvider>();
  return showReorderSheet(
    context,
    title: l10n.settingsReorderSections,
    items: [
      for (final id in settings.settingsSectionOrder)
        ReorderItem(id: id.name, label: _sectionLabel(l10n, id), icon: _sectionIcons[id]),
    ],
    defaultOrder: [for (final id in SettingsSectionId.values) id.name],
    onChanged: (names) => settings.setSettingsSectionOrder(
      names.map(SettingsSectionId.values.byName).toList(),
    ),
  );
}

Future<void> _showTabOrderSheet(BuildContext context) {
  final l10n = AppLocalizations.of(context)!;
  final settings = context.read<SettingsProvider>();
  return showReorderSheet(
    context,
    title: l10n.settingsTabOrder,
    items: [
      for (final id in settings.navTabOrder)
        ReorderItem(id: id.name, label: navTabDef(id).label(l10n), icon: navTabDef(id).icon),
    ],
    defaultOrder: [for (final id in NavTabId.values) id.name],
    onChanged: (names) => settings.setNavTabOrder(names.map(NavTabId.values.byName).toList()),
  );
}

/// [tab] null es "Última usada".
String _startTabLabel(AppLocalizations l10n, NavTabId? tab) =>
    tab == null ? l10n.settingsStartTabLastUsed : navTabDef(tab).label(l10n);

Future<void> _showStartTabSheet(BuildContext context) {
  final l10n = AppLocalizations.of(context)!;
  final settings = context.read<SettingsProvider>();
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppTheme.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.settingsStartTab,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            for (final tab in <NavTabId?>[null, ...settings.navTabOrder])
              ListTile(
                key: Key('start_tab_${serializeStartTab(tab)}'),
                contentPadding: EdgeInsets.zero,
                title: Text(
                  _startTabLabel(l10n, tab),
                  style: const TextStyle(color: Colors.white),
                ),
                trailing: settings.startTab == tab
                    ? Icon(Icons.check_rounded, color: AppTheme.primaryLight)
                    : null,
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  settings.setStartTab(tab);
                },
              ),
          ],
        ),
      ),
    ),
  );
}

class _StorageSection extends StatelessWidget {
  const _StorageSection();

  /// El audio real de las canciones importadas o descargadas vive en la
  /// carpeta SAF que eligió el usuario, no en un `File` que `dart:io` pueda
  /// leer (D1) — antes esto sólo sumaba `File(song.filePath)`, que para esas
  /// canciones está vacío, así que el número mostrado ignoraba casi todo lo
  /// que realmente ocupa espacio. Se suma aparte: el tamaño real de la
  /// carpeta (vía SAF) más lo que sigue siendo legítimamente un `File` —
  /// descargas heredadas pre-pivot y las miniaturas, que siempre viven en
  /// almacenamiento privado sin importar el origen de la canción (D5).
  Future<String> _calculateStorageUsage(BuildContext context, String? libraryRootUri) async {
    try {
      int totalBytes = 0;

      if (libraryRootUri != null) {
        totalBytes += await StorageService().calculateLibrarySize(libraryRootUri);
      }

      final songs = await DatabaseHelper.instance.getSongs();
      for (final song in songs) {
        if (song.uri == null || song.uri!.isEmpty) {
          try {
            final audioFile = File(song.filePath);
            if (await audioFile.exists()) {
              totalBytes += await audioFile.length();
            }
          } catch (_) {}
        }

        try {
          if (song.artPath.isNotEmpty) {
            final artFile = File(song.artPath);
            if (await artFile.exists()) {
              totalBytes += await artFile.length();
            }
          }
        } catch (_) {}
      }

      return _formatBytes(totalBytes);
    } catch (e) {
      return context.mounted ? AppLocalizations.of(context)!.settingsCalcError : 'Error calculando';
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024)
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final musicProvider = context.watch<MusicProvider>();
    final l10n = AppLocalizations.of(context)!;
    return Container(
      decoration: AppTheme.glassCard(),
      padding: const EdgeInsets.all(16),
      child: FutureBuilder<String>(
        key: ValueKey(musicProvider.libraryRootUri),
        future: _calculateStorageUsage(context, musicProvider.libraryRootUri),
        builder: (context, snapshot) {
          final storage = snapshot.data ?? l10n.settingsCalculating;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.storage_rounded,
                    color: AppTheme.primaryLight,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    l10n.settingsSpaceUsed,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.7),
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                storage,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                l10n.settingsTotalDownloadedSongs,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.45),
                  fontSize: 12,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _AppearanceSection extends StatelessWidget {
  const _AppearanceSection();

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final l10n = AppLocalizations.of(context)!;
    return Container(
      decoration: AppTheme.glassCard(),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.settingsThemeColor,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.7),
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 12),
          ...AppThemePreset.values.map((preset) {
            final selected = settings.preset == preset;
            final isCustom = preset == AppThemePreset.custom;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: selected
                    ? AppTheme.primary.withValues(alpha: 0.2)
                    : Colors.white.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => isCustom
                      ? _showCustomThemeSheet(context, settings)
                      : settings.setPreset(preset),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        _PresetDot(preset: preset),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            settings.presetLabel(context, preset),
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: selected
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                          ),
                        ),
                        if (isCustom)
                          Icon(
                            Icons.tune_rounded,
                            color: selected
                                ? AppTheme.primaryLight
                                : Colors.white.withValues(alpha: 0.4),
                            size: 20,
                          )
                        else if (selected)
                          Icon(
                            Icons.check_circle_rounded,
                            color: AppTheme.primaryLight,
                            size: 20,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }),
          const Divider(height: 24, color: Colors.white12),
          SwitchListTile(
            key: const Key('dynamic_now_playing_color_switch'),
            contentPadding: EdgeInsets.zero,
            activeThumbColor: AppTheme.primaryLight,
            value: settings.dynamicNowPlayingColor,
            title: Text(
              l10n.settingsDynamicNowPlayingColor,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
            subtitle: Text(
              l10n.settingsDynamicNowPlayingColorBody,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 11),
            ),
            onChanged: settings.setDynamicNowPlayingColor,
          ),
          ListTile(
            key: const Key('area_colors_entry'),
            contentPadding: EdgeInsets.zero,
            title: Text(
              l10n.settingsAreaColors,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
            subtitle: Text(
              l10n.settingsAreaColorsBody,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 11),
            ),
            trailing: Icon(
              Icons.chevron_right_rounded,
              color: Colors.white.withValues(alpha: 0.4),
            ),
            onTap: () => showAreaColorsSheet(context),
          ),
          ListTile(
            key: const Key('text_style_entry'),
            contentPadding: EdgeInsets.zero,
            title: Text(
              l10n.settingsTextStyle,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
            subtitle: Text(
              l10n.settingsTextStyleBody,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 11),
            ),
            trailing: Icon(
              Icons.chevron_right_rounded,
              color: Colors.white.withValues(alpha: 0.4),
            ),
            onTap: () => showTextStyleSheet(context),
          ),
          ListTile(
            key: const Key('now_playing_layout_entry'),
            contentPadding: EdgeInsets.zero,
            title: Text(
              l10n.settingsNowPlayingLayout,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
            subtitle: Text(
              l10n.settingsNowPlayingLayoutBody,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 11),
            ),
            trailing: Icon(
              Icons.chevron_right_rounded,
              color: Colors.white.withValues(alpha: 0.4),
            ),
            onTap: () => showNowPlayingLayoutSheet(context),
          ),
          ListTile(
            key: const Key('nav_tab_order_entry'),
            contentPadding: EdgeInsets.zero,
            title: Text(
              l10n.settingsTabOrder,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
            trailing: Icon(
              Icons.chevron_right_rounded,
              color: Colors.white.withValues(alpha: 0.4),
            ),
            onTap: () => _showTabOrderSheet(context),
          ),
          ListTile(
            key: const Key('start_tab_entry'),
            contentPadding: EdgeInsets.zero,
            title: Text(
              l10n.settingsStartTab,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
            subtitle: Text(
              _startTabLabel(l10n, settings.startTab),
              style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 11),
            ),
            trailing: Icon(
              Icons.chevron_right_rounded,
              color: Colors.white.withValues(alpha: 0.4),
            ),
            onTap: () => _showStartTabSheet(context),
          ),
        ],
      ),
    );
  }
}

class _LanguageSection extends StatelessWidget {
  const _LanguageSection();

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    return Container(
      decoration: AppTheme.glassCard(),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ...AppLanguage.values.map((lang) {
            final selected = settings.language == lang;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: selected
                    ? AppTheme.primary.withValues(alpha: 0.2)
                    : Colors.white.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => settings.setLanguage(lang),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.language_rounded,
                          color: selected ? AppTheme.primaryLight : Colors.white54,
                          size: 20,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            settings.languageLabel(lang),
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                            ),
                          ),
                        ),
                        if (selected)
                          Icon(
                            Icons.check_circle_rounded,
                            color: AppTheme.primaryLight,
                            size: 20,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}

class _PlaylistOrderSection extends StatelessWidget {
  const _PlaylistOrderSection();

  @override
  Widget build(BuildContext context) {
    final musicProvider = context.watch<MusicProvider>();
    final l10n = AppLocalizations.of(context)!;
    return Container(
      decoration: AppTheme.glassCard(),
      child: musicProvider.playlists.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                l10n.settingsCreatePlaylistsHint,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.45),
                ),
              ),
            )
          : ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: musicProvider.playlists.length,
              onReorder: (oldIndex, newIndex) async {
                if (newIndex > oldIndex) newIndex--;
                final list = [...musicProvider.playlists];
                final item = list.removeAt(oldIndex);
                list.insert(newIndex, item);
                await musicProvider.reorderPlaylists(list);
              },
              itemBuilder: (context, index) {
                final p = musicProvider.playlists[index];
                return ListTile(
                  key: ValueKey(p.id),
                  leading: ReorderableDragStartListener(
                    index: index,
                    child: Icon(
                      Icons.drag_handle_rounded,
                      color: Colors.white.withValues(alpha: 0.4),
                    ),
                  ),
                  title: Text(
                    p.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  trailing: Text(
                    '#${index + 1}',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.35),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class _LocalLibrarySection extends StatelessWidget {
  const _LocalLibrarySection();

  Future<void> _pickLibraryFolder(BuildContext context) async {
    final storageService = StorageService();
    try {
      final rootUri = await storageService.pickLibraryRoot();
      if (!context.mounted) return;
      if (rootUri == null) return; // user cancelled the picker
      // Notify MusicProvider immediately so Bandeja (kept alive by the
      // bottom nav's IndexedStack) reflects the pick without the user
      // having to navigate away and back.
      context.read<MusicProvider>().setLibraryRootUri(rootUri);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.settingsFolderReadySnack),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.settingsFolderPickError(
              localizedErrorReport(AppLocalizations.of(context)!, e, area: 'FS'),
            )),
          backgroundColor: Colors.red.withValues(alpha: 0.8),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      decoration: AppTheme.glassCard(),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.folder_open_rounded,
                color: AppTheme.primaryLight,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                l10n.settingsImportFromFolder,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 13,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            l10n.settingsImportFolderBody,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.45),
              fontSize: 12,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: BorderSide(
                  color: Colors.white.withValues(alpha: 0.3),
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              icon: const Icon(Icons.folder_rounded, size: 18),
              label: Text(
                l10n.settingsChooseFolder,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              onPressed: () => _pickLibraryFolder(context),
            ),
          ),
        ],
      ),
    );
  }
}

class _IgnoredRecommendationsSection extends StatelessWidget {
  const _IgnoredRecommendationsSection();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final count = context.watch<FolderSyncProvider>().ignoredRecommendations.length;
    return Container(
      decoration: AppTheme.glassCard(),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.ignoredRecsSectionBody,
            style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 12, height: 1.4),
          ),
          TextButton(
            key: const Key('ignored_recs_open'),
            style: TextButton.styleFrom(alignment: Alignment.centerLeft, foregroundColor: Colors.white),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const IgnoredRecommendationsScreen())),
            child: Text(l10n.ignoredRecsOpen(count)),
          ),
        ],
      ),
    );
  }
}

class _SearchSection extends StatelessWidget {
  const _SearchSection();

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final l10n = AppLocalizations.of(context)!;
    return Container(
      decoration: AppTheme.glassCard(),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.search_rounded,
                color: AppTheme.primaryLight,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                l10n.settingsMaxResults,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 13,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            l10n.settingsMaxResultsBody,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.45),
              fontSize: 12,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.remove, size: 20),
                color: AppTheme.primaryLight,
                onPressed: settings.maxSearchResults > 10
                    ? () => settings.setMaxSearchResults(
                        settings.maxSearchResults - 10,
                      )
                    : null,
              ),
              Expanded(
                child: Text(
                  '${settings.maxSearchResults}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add, size: 20),
                color: AppTheme.primaryLight,
                onPressed: settings.maxSearchResults < 200
                    ? () => settings.setMaxSearchResults(
                        settings.maxSearchResults + 10,
                      )
                    : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AboutSection extends StatelessWidget {
  const _AboutSection();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      decoration: AppTheme.glassCard(),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Heardy',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            l10n.settingsAboutBody,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.45),
              fontSize: 13,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 2),
          const _AppVersionLabel(),
          const SizedBox(height: 10),
          Text(
            l10n.settingsAboutExternalServices,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.35),
              fontSize: 12,
              height: 1.4,
            ),
          ),
          if (Platform.isWindows) ...[
            const SizedBox(height: 10),
            Text(
              l10n.settingsAboutThirdParty,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.35),
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ],
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: BorderSide(color: Colors.white.withValues(alpha: 0.3)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              icon: const Icon(Icons.gavel_rounded, size: 18),
              label: Text(l10n.legalTitle, style: const TextStyle(fontWeight: FontWeight.w600)),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const LegalScreen()),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
