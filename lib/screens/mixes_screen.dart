import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/mix_record.dart';
import '../models/playlist.dart';
import '../providers/music_provider.dart';
import '../services/audio_player_handler.dart';
import '../services/mix/mix_library.dart';
import '../services/mix/mix_naming.dart';
import '../services/mix/mixer_logic.dart';
import '../theme/app_theme.dart';
import '../widgets/desktop_shell_scope.dart';
import '../widgets/max_width_center.dart';
import '../widgets/mix_cover_image.dart';
import '../widgets/playlist_target_sheet.dart';
import 'heardy_mixer_result_screen.dart';
import 'heardy_mixer_screen.dart';

/// Conecta "Ver en Mixes" del resultado de Heardy Mixer con esta sección.
void registerMixesSection() {
  HeardyMixerResultScreen.openMixes = (context, _) => Navigator.of(context).push(MixesScreen.route());
}

/// Sección Mixes de Explorar: los mixes guardados en este dispositivo. Funciona
/// sin sesión y sin red; escuchar un mix es efímero (sin fila en `songs` ni
/// historial) y guardarlo lo copia a una playlist de descargas.
class MixesScreen extends StatefulWidget {
  const MixesScreen({
    super.key,
    this.library,
    this.play,
    this.pickPlaylist,
    this.openMixer,
    this.onLibraryChanged,
  });

  /// Por defecto, el [MixLibrary] del `MultiProvider`.
  final MixLibrary? library;

  /// Por defecto, [AudioPlayerHandler.playEphemeralFile].
  final Future<void> Function(MixRecord record)? play;

  /// Devuelve el id de una playlist local, o `null` si se canceló. Por
  /// defecto, el selector de destino de las descargas.
  final Future<String?> Function(BuildContext context)? pickPlaylist;
  final void Function(BuildContext context)? openMixer;

  /// Tras guardar o borrar una canción de la biblioteca.
  final void Function(BuildContext context)? onLibraryChanged;

  static Route<void> route() => MaterialPageRoute<void>(builder: (_) => const MixesScreen());

  @override
  State<MixesScreen> createState() => _MixesScreenState();
}

class _MixesScreenState extends State<MixesScreen> {
  List<MixEntry>? _entries;
  bool _failed = false;
  String? _busyId;

  MixLibrary get _library => widget.library ?? context.read<MixLibrary>();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final entries = await _library.list();
      if (mounted) {
        setState(() {
          _entries = entries;
          _failed = false;
        });
      }
    } catch (e) {
      print('Mix: no se pudieron listar los mixes (${e.runtimeType})');
      if (mounted) setState(() => _failed = true);
    }
  }

  String get _decimal => Localizations.localeOf(context).languageCode == 'es' ? ',' : '.';

  void _snack(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  void _libraryChanged() {
    final notify = widget.onLibraryChanged;
    if (notify != null) {
      notify(context);
      return;
    }
    final music = context.read<MusicProvider>();
    music.notifyLibraryChanged();
    music.loadPlaylists();
  }

  Future<void> _openMixer() async {
    final open = widget.openMixer;
    if (open != null) {
      open(context);
    } else {
      await Navigator.of(context).push(HeardyMixerScreen.route());
    }
    if (mounted) await _reload();
  }

  Future<void> _play(MixEntry entry) async {
    final l10n = AppLocalizations.of(context)!;
    if (entry.sizeBytes == null) {
      _snack(l10n.mixesMissingFile);
      return;
    }
    final r = entry.record;
    try {
      final play = widget.play ??
          (MixRecord r) => context.read<AudioPlayerHandler>().playEphemeralFile(mixMediaItem(r), r.filePath);
      DesktopShellScope.maybeOf(context)?.openNowPlaying();
      await play(r);
    } catch (e) {
      print('Mix: no se pudo reproducir el mix (${e.runtimeType})');
      if (mounted) _snack(l10n.mixerResultPlayFailed);
    }
  }

  Future<String?> _pickPlaylist() async {
    final pick = widget.pickPlaylist;
    if (pick != null) return pick(context);
    final choice = await pickTargetPlaylist(context, kind: Playlist.kindLocal);
    if (choice == null || !mounted) return null;
    return resolveTargetPlaylistId(context, choice);
  }

  Future<void> _save(MixEntry entry) async {
    final l10n = AppLocalizations.of(context)!;
    final playlistId = await _pickPlaylist();
    if (playlistId == null || !mounted) return;
    setState(() => _busyId = entry.record.id);
    try {
      await _library.saveToPlaylist(entry.record, playlistId);
      if (!mounted) return;
      _libraryChanged();
      _snack(l10n.mixesSaved);
    } catch (e) {
      print('Mix: no se pudo guardar el mix en la playlist (${e.runtimeType})');
      if (mounted) _snack(l10n.mixesSaveFailed);
    } finally {
      if (mounted) setState(() => _busyId = null);
      await _reload();
    }
  }

  Future<void> _rename(MixEntry entry) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _RenameMixDialog(initial: entry.record.name),
    );
    if (name == null || !mounted) return;
    try {
      await _library.rename(entry.record, name);
    } catch (e) {
      print('Mix: no se pudo renombrar el mix (${e.runtimeType})');
    }
    await _reload();
  }

  Future<void> _delete(MixEntry entry) async {
    final l10n = AppLocalizations.of(context)!;
    final MixDeletePreview preview;
    try {
      preview = await _library.deletePreview(entry.record);
    } catch (e) {
      print('Mix: no se pudo preparar el borrado (${e.runtimeType})');
      return;
    }
    if (!mounted) return;
    final size = formatMixSize(preview.sizeBytes ?? 0, decimalSeparator: _decimal);
    var alsoSong = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          backgroundColor: AppTheme.surface,
          title: Text(l10n.mixesDeleteTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.mixesDeleteBody(size)),
              if (preview.savedSong != null)
                CheckboxListTile(
                  key: const Key('mixes_delete_song_too'),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: alsoSong,
                  onChanged: (v) => setDialogState(() => alsoSong = v ?? false),
                  title: Text(l10n.mixesDeleteSavedSong(preview.savedSongPlaylistCount)),
                ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: Text(l10n.commonCancel)),
            TextButton(
              key: const Key('mixes_delete_confirm'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(l10n.mixesDeleteConfirm, style: const TextStyle(color: Colors.redAccent)),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    final removeSong = alsoSong && preview.savedSong != null;
    try {
      await _library.delete(entry.record, alsoSavedSong: removeSong);
      if (!mounted) return;
      if (removeSong) _libraryChanged();
      _snack(l10n.mixesDeleted);
    } catch (e) {
      print('Mix: no se pudo borrar el mix (${e.runtimeType})');
    }
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final entries = _entries;
    return Scaffold(
      body: Container(
        decoration: AppTheme.gradientScaffold(),
        child: SafeArea(
          child: MaxWidthCenter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(kScreenGutter - 8, 8, kScreenGutter - 8, 0),
                  child: Row(children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    Expanded(
                      child: Text(l10n.mixesTitle,
                          style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800)),
                    ),
                    if (entries != null && entries.isNotEmpty)
                      IconButton(
                        key: const Key('mixes_new_mix'),
                        tooltip: l10n.mixesNewMix,
                        icon: const Icon(Icons.add_rounded, color: Colors.white),
                        onPressed: _openMixer,
                      ),
                  ]),
                ),
                Expanded(child: _body(l10n, entries)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(AppLocalizations l10n, List<MixEntry>? entries) {
    if (_failed && entries == null) {
      return Center(child: Text(l10n.mixesLoadFailed, style: const TextStyle(color: Colors.white70)));
    }
    if (entries == null) return const Center(child: CircularProgressIndicator());
    if (entries.isEmpty) return _empty(l10n);
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(kScreenGutter, 8, kScreenGutter, 100),
        itemCount: entries.length,
        itemBuilder: (_, i) => _tile(l10n, entries[i]),
      ),
    );
  }

  Widget _empty(AppLocalizations l10n) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.multitrack_audio_rounded, color: AppTheme.primaryLight, size: 56),
            const SizedBox(height: 16),
            Text(l10n.mixesEmptyTitle,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(l10n.mixesEmptyBody,
                textAlign: TextAlign.center, style: TextStyle(color: Colors.white.withValues(alpha: 0.6))),
            const SizedBox(height: 20),
            AppTheme.gradientButton(
              onPressed: _openMixer,
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
              child: Text(l10n.mixesOpenMixer,
                  key: const Key('mixes_empty_open_mixer'),
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            ),
          ]),
        ),
      );

  Widget _tile(AppLocalizations l10n, MixEntry entry) {
    final r = entry.record;
    final size = entry.sizeBytes;
    final details = [
      formatMixDuration(r.durationMs),
      if (size != null) formatMixSize(size, decimalSeparator: _decimal),
    ].join(' · ');
    final busy = _busyId == r.id;
    return ListTile(
      key: Key('mixes_tile_${r.id}'),
      contentPadding: const EdgeInsets.symmetric(vertical: 4),
      leading: MixCoverImage(record: r),
      title: Text(r.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(combinedMixArtist(r.artistA, r.artistB),
            maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.white.withValues(alpha: 0.7))),
        Row(children: [
          Flexible(child: Text(details, style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 12))),
          if (entry.savedSong != null) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: l10n.mixesSavedBadge,
              child: Icon(Icons.library_music_rounded,
                  key: Key('mixes_saved_${r.id}'), size: 14, color: AppTheme.primaryLight),
            ),
          ],
        ]),
      ]),
      onTap: busy ? null : () => _play(entry),
      trailing: busy
          ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))
          : PopupMenuButton<String>(
              key: Key('mixes_menu_${r.id}'),
              tooltip: l10n.mixesActions,
              icon: const Icon(Icons.more_vert_rounded, color: Colors.white70),
              color: AppTheme.surface,
              onSelected: (action) => switch (action) {
                'rename' => _rename(entry),
                'save' => _save(entry),
                _ => _delete(entry),
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                    key: const Key('mixes_action_rename'), value: 'rename', child: Text(l10n.mixesRename)),
                PopupMenuItem(
                    key: const Key('mixes_action_save'), value: 'save', child: Text(l10n.mixesSaveToPlaylist)),
                PopupMenuItem(
                    key: const Key('mixes_action_delete'), value: 'delete', child: Text(l10n.mixesDelete)),
              ],
            ),
    );
  }
}

/// Dueño de su controlador: el diálogo lo sigue usando durante la animación
/// de salida, así que no puede desecharlo quien lo abrió.
class _RenameMixDialog extends StatefulWidget {
  const _RenameMixDialog({required this.initial});
  final String initial;

  @override
  State<_RenameMixDialog> createState() => _RenameMixDialogState();
}

class _RenameMixDialogState extends State<_RenameMixDialog> {
  late final TextEditingController _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      backgroundColor: AppTheme.surface,
      title: Text(l10n.mixesRenameTitle),
      content: TextField(
        key: const Key('mixes_rename_field'),
        controller: _controller,
        autofocus: true,
        maxLength: kMaxEditedMixNameLength,
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.commonCancel)),
        TextButton(
          key: const Key('mixes_rename_ok'),
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(l10n.mixesRenameSave),
        ),
      ],
    );
  }
}
