import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../models/playlist.dart';
import '../providers/music_provider.dart';
import '../services/import_destination_logic.dart';
import '../services/playlist_filter_logic.dart';
import '../services/stream_resolver.dart';
import 'playlist_kind_picker.dart';
import '../theme/app_theme.dart';
import '../l10n/app_localizations.dart';

/// Resultado del selector: o una playlist existente, o el nombre de una que
/// hay que crear. Compartido entre ImportScreen y SearchScreen — cualquier
/// flujo que descargue una canción necesita elegir UN destino, porque
/// `DownloadService.download` toma un único `playlistId`.
class PlaylistChoice {
  final String? existingPlaylistId;
  final String? newPlaylistName;
  final String newPlaylistKind;
  const PlaylistChoice.existing(this.existingPlaylistId)
    : newPlaylistName = null,
      newPlaylistKind = Playlist.kindLocal;
  const PlaylistChoice.newPlaylist(
    this.newPlaylistName, {
    this.newPlaylistKind = Playlist.kindLocal,
  }) : existingPlaylistId = null;
}

/// Abre el selector y devuelve la elección del usuario (`null` si canceló).
/// [excludePlaylistId] oculta esa playlist de la lista — para "mover"/"copiar"
/// una canción, no tiene sentido ofrecer la playlist en la que ya está.
/// [kind] (`Playlist.kindLocal`/`kindOnline`) limita la lista a ese tipo y
/// fija el tipo de la playlist nueva; sin él se ofrecen todas y la nueva es
/// local, salvo con [allowKindChoice], que deja elegir su tipo.
Future<PlaylistChoice?> pickTargetPlaylist(
  BuildContext context, {
  String? suggestedName,
  String? excludePlaylistId,
  String? kind,
  bool allowKindChoice = false,
}) {
  // Sin streaming no se puede escuchar una playlist online: sólo se ofrecen
  // destinos de descarga.
  if (allowKindChoice && !streamingSupported) kind ??= Playlist.kindLocal;
  var playlists = playlistsOfKind(context.read<MusicProvider>().playlists, kind);
  if (excludePlaylistId != null) {
    playlists = playlists.where((p) => p.id != excludePlaylistId).toList();
  }
  return showModalBottomSheet<PlaylistChoice>(
    context: context,
    backgroundColor: AppTheme.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => PlaylistTargetSheet(
      playlists: playlists,
      suggestedName: suggestedName,
      newPlaylistKind: kind ?? Playlist.kindLocal,
      allowKindChoice: allowKindChoice && kind == null,
    ),
  );
}

/// Convierte la elección del usuario en un `playlistId` real, creando la
/// playlist nueva si hizo falta.
Future<String?> resolveTargetPlaylistId(
  BuildContext context,
  PlaylistChoice choice,
) async {
  if (choice.existingPlaylistId != null) return choice.existingPlaylistId;
  final name = choice.newPlaylistName;
  if (name == null || name.isEmpty) return null;

  final id = const Uuid().v4();
  await context.read<MusicProvider>().createPlaylistWithId(id, name, kind: choice.newPlaylistKind);
  return id;
}

/// Destino ya resuelto (la playlist nueva ya existe) con lo que hace falta para
/// decidir entre descargar y guardar referencias.
class PlaylistDestination {
  final String id;
  final String name;
  final String kind;
  final bool isNew;
  const PlaylistDestination({
    required this.id,
    required this.name,
    required this.kind,
    required this.isNew,
  });

  bool get isOnline => kind == Playlist.kindOnline;
}

/// Abre el selector (con elección de tipo por defecto) y resuelve el destino.
/// `null` si el usuario canceló. [kind] fija el tipo si sólo vale uno.
Future<PlaylistDestination?> pickPlaylistDestination(
  BuildContext context, {
  String? suggestedName,
  String? kind,
  bool allowKindChoice = true,
}) async {
  final choice = await pickTargetPlaylist(
    context,
    suggestedName: suggestedName,
    kind: kind,
    allowKindChoice: allowKindChoice,
  );
  if (choice == null || !context.mounted) return null;
  final playlists = context.read<MusicProvider>().playlists;
  final isNew = choice.existingPlaylistId == null;
  final id = await resolveTargetPlaylistId(context, choice);
  if (id == null || !context.mounted) return null;
  final name = isNew
      ? choice.newPlaylistName!
      : playlists.where((p) => p.id == id).map((p) => p.name).firstOrNull ?? '';
  return PlaylistDestination(
    id: id,
    name: name,
    kind: destinationKind(
      existingPlaylistId: choice.existingPlaylistId,
      newPlaylistKind: choice.newPlaylistKind,
      playlists: playlists,
    ),
    isNew: isNew,
  );
}

/// Elegir UNA playlist destino, existente o nueva — a diferencia del selector
/// multi-select de la bandeja (que asigna canciones YA en la biblioteca a
/// varias playlists a la vez), una descarga va a un solo lugar porque
/// [DownloadService.download] toma un único `playlistId`.
class PlaylistTargetSheet extends StatefulWidget {
  final List<Playlist> playlists;
  final String? suggestedName;
  final String newPlaylistKind;
  final bool allowKindChoice;

  const PlaylistTargetSheet({
    super.key,
    required this.playlists,
    this.suggestedName,
    this.newPlaylistKind = Playlist.kindLocal,
    this.allowKindChoice = false,
  });

  @override
  State<PlaylistTargetSheet> createState() => _PlaylistTargetSheetState();
}

class _PlaylistTargetSheetState extends State<PlaylistTargetSheet> {
  String? _selectedId;
  late final TextEditingController _newNameController;
  late String _newKind = widget.newPlaylistKind;
  PlaylistKindFilter _filter = PlaylistKindFilter.all;

  @override
  void initState() {
    super.initState();
    _newNameController = TextEditingController(
      text: widget.suggestedName ?? '',
    );
  }

  @override
  void dispose() {
    _newNameController.dispose();
    super.dispose();
  }

  String get _effectiveNewKind =>
      widget.allowKindChoice && !streamingSupported ? Playlist.kindLocal : _newKind;

  void _setFilter(PlaylistKindFilter filter) {
    setState(() {
      _filter = filter;
      if (filter == PlaylistKindFilter.downloaded) _newKind = Playlist.kindLocal;
      if (filter == PlaylistKindFilter.notDownloaded && streamingSupported) _newKind = Playlist.kindOnline;
      final selected = _selectedId;
      if (selected != null && !filterPlaylistsByKind(widget.playlists, filter).any((p) => p.id == selected)) {
        _selectedId = null;
      }
    });
  }

  Widget _buildFilterRow(AppLocalizations l10n) {
    final labels = {
      PlaylistKindFilter.all: l10n.homeFilterAll,
      PlaylistKindFilter.downloaded: l10n.homeFilterDownloaded,
      PlaylistKindFilter.notDownloaded: l10n.homeFilterNotDownloaded,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final entry in labels.entries) ...[
              ChoiceChip(
                key: Key('target_filter_${entry.key.name}'),
                label: Text(entry.value),
                selected: _filter == entry.key,
                showCheckmark: false,
                selectedColor: AppTheme.primary,
                backgroundColor: Colors.white.withValues(alpha: 0.06),
                side: BorderSide.none,
                labelStyle: TextStyle(
                  color: Colors.white.withValues(alpha: _filter == entry.key ? 1 : 0.7),
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
                onSelected: (_) => _setFilter(entry.key),
              ),
              const SizedBox(width: 8),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final visiblePlaylists = widget.allowKindChoice
        ? filterPlaylistsByKind(widget.playlists, _filter)
        : widget.playlists;
    final newName = _newNameController.text.trim();
    final canConfirm = _selectedId != null || newName.isNotEmpty;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        // Alto máximo explícito desde el primer frame: sin esto, con muchas
        // playlists el `ListView(shrinkWrap: true)` de abajo se dimensiona
        // por su alto intrínseco (la suma de TODAS las filas) mientras el
        // sheet todavía está animando su entrada — el layout se recalcula a
        // mitad de la animación de deslizamiento y el sheet "salta" al fondo
        // en vez de terminar de subir. Acotando el alto acá, `Flexible` de
        // abajo tiene un límite real desde el arranque y el `ListView` sólo
        // ocupa lo que le sobra, ya scrolleable.
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.9,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                child: Text(
                  l10n.playlistTargetSheetTitle,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (widget.allowKindChoice) _buildFilterRow(l10n),
              if (visiblePlaylists.isNotEmpty)
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: visiblePlaylists.map((playlist) {
                      return RadioListTile<String>(
                        key: Key('playlist_radio_${playlist.id}'),
                        value: playlist.id,
                        groupValue: _selectedId,
                        onChanged: (value) => setState(() {
                          _selectedId = value;
                          _newNameController.clear();
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
                  key: const Key('new_playlist_name_field'),
                  controller: _newNameController,
                  onChanged: (_) => setState(() {
                    if (_newNameController.text.trim().isNotEmpty)
                      _selectedId = null;
                  }),
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: l10n.commonCreateNewPlaylistHint,
                    prefixIcon: const Icon(Icons.add_rounded),
                  ),
                ),
              ),
              if (widget.allowKindChoice && newName.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                  child: PlaylistKindPicker(
                    value: _newKind,
                    streamingAvailable: streamingSupported,
                    onChanged: (k) => setState(() => _newKind = k),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(20),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    key: const Key('confirm_playlist_choice'),
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
                            _selectedId != null
                                ? PlaylistChoice.existing(_selectedId)
                                : PlaylistChoice.newPlaylist(
                                    newName,
                                    newPlaylistKind: _effectiveNewKind,
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
