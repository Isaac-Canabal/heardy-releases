import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../models/playlist.dart';
import '../providers/music_provider.dart';
import '../theme/app_theme.dart';
import '../l10n/app_localizations.dart';

/// Resultado del selector: o una playlist existente, o el nombre de una que
/// hay que crear. Compartido entre ImportScreen y SearchScreen — cualquier
/// flujo que descargue una canción necesita elegir UN destino, porque
/// `DownloadService.download` toma un único `playlistId`.
class PlaylistChoice {
  final String? existingPlaylistId;
  final String? newPlaylistName;
  const PlaylistChoice.existing(this.existingPlaylistId)
    : newPlaylistName = null;
  const PlaylistChoice.newPlaylist(this.newPlaylistName)
    : existingPlaylistId = null;
}

/// Abre el selector y devuelve la elección del usuario (`null` si canceló).
/// [excludePlaylistId] oculta esa playlist de la lista — para "mover"/"copiar"
/// una canción, no tiene sentido ofrecer la playlist en la que ya está.
Future<PlaylistChoice?> pickTargetPlaylist(
  BuildContext context, {
  String? suggestedName,
  String? excludePlaylistId,
}) {
  var playlists = context.read<MusicProvider>().playlists;
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
    builder: (_) =>
        PlaylistTargetSheet(playlists: playlists, suggestedName: suggestedName),
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
  await context.read<MusicProvider>().createPlaylistWithId(id, name);
  return id;
}

/// Elegir UNA playlist destino, existente o nueva — a diferencia del selector
/// multi-select de la bandeja (que asigna canciones YA en la biblioteca a
/// varias playlists a la vez), una descarga va a un solo lugar porque
/// [DownloadService.download] toma un único `playlistId`.
class PlaylistTargetSheet extends StatefulWidget {
  final List<Playlist> playlists;
  final String? suggestedName;

  const PlaylistTargetSheet({
    super.key,
    required this.playlists,
    this.suggestedName,
  });

  @override
  State<PlaylistTargetSheet> createState() => _PlaylistTargetSheetState();
}

class _PlaylistTargetSheetState extends State<PlaylistTargetSheet> {
  String? _selectedId;
  late final TextEditingController _newNameController;

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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
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
            maxHeight: MediaQuery.of(context).size.height * 0.75,
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
              if (widget.playlists.isNotEmpty)
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: widget.playlists.map((playlist) {
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
                                : PlaylistChoice.newPlaylist(newName),
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
