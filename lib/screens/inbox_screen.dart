import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../models/playlist.dart';
import '../models/song.dart';
import '../providers/music_provider.dart';
import '../services/database_helper.dart';
import '../services/storage_service.dart';
import '../services/library_scan_service.dart';
import '../theme/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../services/friendly_error.dart';

/// Batch triage for songs imported loose in the library root, with no
/// playlist assigned yet (D6). Never a per-song dialog — select as many as
/// you like, then assign or ignore them all at once.
class InboxScreen extends StatefulWidget {
  const InboxScreen({super.key});

  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  final _storageService = StorageService();
  List<Song> _songs = [];
  List<Song> _ignoredSongs = [];
  final Set<String> _selectedIds = {};
  bool _loading = true;
  bool _scanning = false;
  bool _showIgnored = false;

  List<Song> get _activeSongs => _showIgnored ? _ignoredSongs : _songs;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final songs = await DatabaseHelper.instance.getInboxSongs();
    final ignored = await DatabaseHelper.instance.getIgnoredSongs();
    if (!mounted) return;
    setState(() {
      _songs = songs;
      _ignoredSongs = ignored;
      _selectedIds.removeWhere((id) => !_activeSongs.any((s) => s.id == id));
      _loading = false;
    });
  }

  void _switchTab(bool showIgnored) {
    setState(() {
      _showIgnored = showIgnored;
      _selectedIds.clear();
    });
  }

  Future<void> _pickFolder() async {
    try {
      final rootUri = await _storageService.pickLibraryRoot();
      if (!mounted || rootUri == null) return;
      context.read<MusicProvider>().setLibraryRootUri(rootUri);
    } catch (e) {
      if (!mounted) return;
      _showSnack(
        AppLocalizations.of(context)!.settingsFolderPickError(
          localizedErrorReport(AppLocalizations.of(context)!, e, area: 'FS'),
        ),
        isError: true,
      );
    }
  }

  Future<void> _scan() async {
    final rootUri = context.read<MusicProvider>().libraryRootUri;
    if (rootUri == null) {
      await _pickFolder();
      return;
    }

    setState(() => _scanning = true);
    try {
      final result = await LibraryScanService().scan(rootUri);
      final musicProvider = context.read<MusicProvider>();
      await musicProvider.loadPlaylists();
      await musicProvider.refreshInboxCount();
      musicProvider.notifyLibraryChanged();
      await _load();
      if (!mounted) return;
      final l10n = AppLocalizations.of(context)!;
      _showSnack(
        l10n.inboxScanSummaryBase(
              result.inserted,
              result.moved,
              result.updated,
              result.unchanged,
            ) +
            (result.missing > 0
                ? l10n.inboxScanMissingSuffix(result.missing)
                : ''),
      );
    } on LibraryRootUnavailableException {
      // The scanner already tombstoned every previously-imported song
      // (same mechanism as a normal missing file) before this was thrown —
      // just forget the dead root so the picker becomes the obvious next
      // step, instead of every future scan repeating this same failure.
      await _storageService.clearLibraryRootUri();
      if (!mounted) return;
      context.read<MusicProvider>().setLibraryRootUri(null);
      await context.read<MusicProvider>().refreshInboxCount();
      await _load();
      if (!mounted) return;
      final l10n = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.inboxRootUnavailable),
          backgroundColor: Colors.red.withValues(alpha: 0.8),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 6),
          action: SnackBarAction(
            label: l10n.settingsChooseFolder,
            onPressed: _pickFolder,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      _showSnack(
        AppLocalizations.of(context)!.inboxScanError(
          localizedErrorReport(AppLocalizations.of(context)!, e, area: 'FS'),
        ),
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  void _showSnack(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red.withValues(alpha: 0.8) : null,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  void _toggleSelectAll() {
    setState(() {
      if (_selectedIds.length == _activeSongs.length) {
        _selectedIds.clear();
      } else {
        _selectedIds
          ..clear()
          ..addAll(_activeSongs.map((s) => s.id));
      }
    });
  }

  Future<void> _ignoreSelected() async {
    final ids = _selectedIds.toList();
    await DatabaseHelper.instance.ignoreSongsFromInbox(ids);
    if (!mounted) return;
    setState(() => _selectedIds.clear());
    await _load();
    if (!mounted) return;
    await context.read<MusicProvider>().refreshInboxCount();
    if (!mounted) return;
    _showSnack(
      AppLocalizations.of(context)!.inboxIgnoredCountSnack(ids.length),
    );
  }

  /// Reverses [_ignoreSelected] — a dismiss must never be a dead end.
  Future<void> _restoreSelected() async {
    final ids = _selectedIds.toList();
    await DatabaseHelper.instance.unignoreSongsFromInbox(ids);
    if (!mounted) return;
    setState(() => _selectedIds.clear());
    await _load();
    if (!mounted) return;
    await context.read<MusicProvider>().refreshInboxCount();
    if (!mounted) return;
    _showSnack(
      AppLocalizations.of(context)!.inboxRestoredCountSnack(ids.length),
    );
  }

  Future<void> _assignSelected() async {
    final musicProvider = context.read<MusicProvider>();
    final result = await showModalBottomSheet<_AssignResult>(
      context: context,
      backgroundColor: AppTheme.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) =>
          _AssignToPlaylistsSheet(playlists: musicProvider.playlists),
    );
    if (result == null || !mounted) return;

    var playlistIds = result.playlistIds;
    if (result.newPlaylistName != null && result.newPlaylistName!.isNotEmpty) {
      final newId = const Uuid().v4();
      await DatabaseHelper.instance.insertPlaylist(
        Playlist(
          id: newId,
          name: result.newPlaylistName!,
          creationDate: DateTime.now(),
        ),
      );
      playlistIds = [...playlistIds, newId];
    }
    if (playlistIds.isEmpty) return;

    final ids = _selectedIds.toList();
    await DatabaseHelper.instance.assignSongsToPlaylists(ids, playlistIds);
    if (!mounted) return;
    setState(() => _selectedIds.clear());
    await musicProvider.loadPlaylists();
    await musicProvider.refreshInboxCount();
    await _load();
    if (!mounted) return;
    _showSnack(
      AppLocalizations.of(context)!.inboxAssignedCountSnack(ids.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasSelection = _selectedIds.isNotEmpty;
    final libraryRootUri = context.watch<MusicProvider>().libraryRootUri;
    final l10n = AppLocalizations.of(context)!;

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.inboxTitle,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5,
                        ),
                      ),
                      if (_activeSongs.isNotEmpty)
                        Text(
                          _showIgnored
                              ? l10n.inboxSubtitleIgnored
                              : l10n.inboxSubtitleLoose,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.5),
                            fontSize: 13,
                          ),
                        ),
                    ],
                  ),
                ),
                _CircleIconButton(
                  icon: Icons.refresh_rounded,
                  loading: _scanning,
                  onTap: _scanning ? null : _scan,
                ),
              ],
            ),
          ),
          if (libraryRootUri != null && !_loading)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
              child: Row(
                children: [
                  ChoiceChip(
                    label: Text(l10n.inboxTabActive(_songs.length)),
                    selected: !_showIgnored,
                    onSelected: (_) => _switchTab(false),
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: Text(l10n.inboxTabIgnored(_ignoredSongs.length)),
                    selected: _showIgnored,
                    onSelected: (_) => _switchTab(true),
                  ),
                ],
              ),
            ),
          if (_activeSongs.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: _toggleSelectAll,
                    icon: Icon(
                      _selectedIds.length == _activeSongs.length
                          ? Icons.check_box_rounded
                          : Icons.check_box_outline_blank_rounded,
                      size: 18,
                    ),
                    label: Text(
                      _selectedIds.length == _activeSongs.length
                          ? l10n.inboxSelectNone
                          : l10n.inboxSelectAll,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    _showIgnored
                        ? l10n.inboxCountIgnoredSuffix(_activeSongs.length)
                        : l10n.inboxCountUnassignedSuffix(_activeSongs.length),
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : libraryRootUri == null
                ? _buildNoFolderState()
                : _activeSongs.isEmpty
                ? (_showIgnored ? _buildNoIgnoredState() : _buildEmptyState())
                : ListView.builder(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      8,
                      16,
                      hasSelection ? 100 : 90,
                    ),
                    itemCount: _activeSongs.length,
                    itemBuilder: (context, index) {
                      final song = _activeSongs[index];
                      final selected = _selectedIds.contains(song.id);
                      return _InboxSongRow(
                        song: song,
                        selected: selected,
                        onTap: () => setState(() {
                          if (selected) {
                            _selectedIds.remove(song.id);
                          } else {
                            _selectedIds.add(song.id);
                          }
                        }),
                      );
                    },
                  ),
          ),
          if (hasSelection)
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              decoration: BoxDecoration(
                color: AppTheme.surface,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 12,
                  ),
                ],
              ),
              child: SafeArea(
                top: false,
                child: _showIgnored
                    ? SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.primary,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          icon: const Icon(Icons.restore_rounded, size: 18),
                          label: Text(
                            l10n.inboxRestoreButton(_selectedIds.length),
                          ),
                          onPressed: _restoreSelected,
                        ),
                      )
                    : Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.white,
                                side: BorderSide(
                                  color: Colors.white.withValues(alpha: 0.3),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              icon: const Icon(
                                Icons.visibility_off_rounded,
                                size: 18,
                              ),
                              label: Text(
                                l10n.inboxIgnoreButton(_selectedIds.length),
                              ),
                              onPressed: _ignoreSelected,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            flex: 2,
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppTheme.primary,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              icon: const Icon(
                                Icons.playlist_add_rounded,
                                size: 18,
                              ),
                              label: Text(
                                l10n.inboxAssignButton(_selectedIds.length),
                              ),
                              onPressed: _assignSelected,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildNoFolderState() {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.folder_off_rounded,
              size: 56,
              color: Colors.white.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 16),
            Text(
              l10n.inboxNoFolderTitle,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              l10n.inboxNoFolderBody,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 13,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: const Icon(Icons.folder_rounded, size: 18),
              label: Text(l10n.settingsChooseFolder),
              onPressed: _pickFolder,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.inbox_rounded,
              size: 56,
              color: Colors.white.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 16),
            Text(
              l10n.inboxEmptyTitle,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.inboxEmptyBody,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 13,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoIgnoredState() {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.visibility_off_rounded,
              size: 56,
              color: Colors.white.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 16),
            Text(
              l10n.inboxNoIgnoredTitle,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.inboxNoIgnoredBody,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 13,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _InboxSongRow extends StatelessWidget {
  final Song song;
  final bool selected;
  final VoidCallback onTap;

  const _InboxSongRow({
    required this.song,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected
            ? AppTheme.primary.withValues(alpha: 0.25)
            : AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                Checkbox(
                  value: selected,
                  onChanged: (_) => onTap(),
                  activeColor: AppTheme.primary,
                ),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: _buildArt(),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        song.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.55),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildArt() {
    if (song.artPath.isNotEmpty) {
      final file = File(song.artPath);
      if (file.existsSync()) {
        return Image.file(file, width: 44, height: 44, fit: BoxFit.cover);
      }
    }
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        gradient: AppTheme.gradientForTitle(song.title),
      ),
      child: const Icon(
        Icons.music_note_rounded,
        color: Colors.white70,
        size: 20,
      ),
    );
  }
}

class _AssignResult {
  final List<String> playlistIds;
  final String? newPlaylistName;
  const _AssignResult(this.playlistIds, this.newPlaylistName);
}

class _AssignToPlaylistsSheet extends StatefulWidget {
  final List<Playlist> playlists;
  const _AssignToPlaylistsSheet({required this.playlists});

  @override
  State<_AssignToPlaylistsSheet> createState() =>
      _AssignToPlaylistsSheetState();
}

class _AssignToPlaylistsSheetState extends State<_AssignToPlaylistsSheet> {
  final Set<String> _selected = {};
  final _newPlaylistController = TextEditingController();

  @override
  void dispose() {
    _newPlaylistController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final newName = _newPlaylistController.text.trim();
    final canConfirm = _selected.isNotEmpty || newName.isNotEmpty;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        // Ver el mismo comentario en PlaylistTargetSheet: sin un alto máximo
        // explícito acá, muchas playlists hacen que el `ListView(shrinkWrap:
        // true)` de abajo recalcule su alto intrínseco a mitad de la
        // animación de apertura del sheet, y éste "salta" al fondo en vez de
        // terminar de deslizarse hacia arriba.
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.75,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                child: Text(
                  l10n.inboxAssignSheetTitle,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (widget.playlists.isNotEmpty)
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: widget.playlists.map((playlist) {
                      final checked = _selected.contains(playlist.id);
                      return CheckboxListTile(
                        value: checked,
                        onChanged: (_) => setState(() {
                          checked
                              ? _selected.remove(playlist.id)
                              : _selected.add(playlist.id);
                        }),
                        activeColor: AppTheme.primary,
                        title: Text(
                          playlist.name,
                          style: const TextStyle(color: Colors.white),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: TextField(
                  controller: _newPlaylistController,
                  onChanged: (_) => setState(() {}),
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: l10n.commonCreateNewPlaylistHint,
                    prefixIcon: const Icon(Icons.add_rounded),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(20),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: canConfirm
                        ? () => Navigator.pop(
                            context,
                            _AssignResult(
                              _selected.toList(),
                              newName.isEmpty ? null : newName,
                            ),
                          )
                        : null,
                    child: Text(l10n.commonConfirm),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CircleIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final bool loading;

  const _CircleIconButton({
    required this.icon,
    required this.onTap,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.primary,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: loading
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : Icon(icon, color: Colors.white, size: 22),
        ),
      ),
    );
  }
}
