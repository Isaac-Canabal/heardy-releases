import 'dart:io';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/song.dart';
import '../services/database_helper.dart';
import '../services/download_source.dart';
import '../services/input_sanitizer.dart';
import '../theme/app_theme.dart';
import 'max_width_center.dart';

Future<List<Song>> _librarySongs() async =>
    (await DatabaseHelper.instance.getSongs()).where((s) => !s.missing).toList();

/// Elige una canción de la biblioteca (descargada o importada).
Future<Song?> showMixerLibraryPicker(BuildContext context, {Future<List<Song>> Function()? load}) {
  return showModalBottomSheet<Song>(
    context: context,
    backgroundColor: AppTheme.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => FractionallySizedBox(heightFactor: 0.85, child: _LibraryPicker(load: load ?? _librarySongs)),
  );
}

/// Busca en YouTube desde el dispositivo ([DownloadSource.search]). Devuelve el
/// resultado tal cual: quien lo use debe volver a resolverlo.
Future<RemoteTrack?> showMixerSearchPicker(BuildContext context, {required DownloadSource source}) {
  return showModalBottomSheet<RemoteTrack>(
    context: context,
    backgroundColor: AppTheme.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => FractionallySizedBox(heightFactor: 0.85, child: _SearchPicker(source: source)),
  );
}

class _LibraryPicker extends StatefulWidget {
  const _LibraryPicker({required this.load});
  final Future<List<Song>> Function() load;

  @override
  State<_LibraryPicker> createState() => _LibraryPickerState();
}

class _LibraryPickerState extends State<_LibraryPicker> {
  List<Song>? _songs;
  String _filter = '';

  @override
  void initState() {
    super.initState();
    widget.load().then((s) {
      if (mounted) setState(() => _songs = s);
    }).catchError((Object e) {
      print('Mix: no se pudo leer la biblioteca (${e.runtimeType})');
      if (mounted) setState(() => _songs = const []);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final q = _filter.toLowerCase();
    final songs = _songs
        ?.where((s) => q.isEmpty || s.title.toLowerCase().contains(q) || s.artist.toLowerCase().contains(q))
        .toList();
    return _PickerFrame(
      title: l10n.mixerPickerLibraryTitle,
      field: TextField(
        key: const Key('mixer_library_filter'),
        onChanged: (v) => setState(() => _filter = sanitizeSearchInput(v)),
        decoration: _fieldDecoration(l10n.mixerPickerFilterHint),
        style: const TextStyle(color: Colors.white),
      ),
      child: songs == null
          ? const Center(child: CircularProgressIndicator())
          : songs.isEmpty
              ? _Empty(l10n.mixerPickerEmpty)
              : ListView.builder(
                  itemCount: songs.length,
                  itemBuilder: (_, i) {
                    final s = songs[i];
                    return _PickerRow(
                      title: s.title,
                      subtitle: s.artist,
                      leading: MixerArt(path: s.artPath, title: s.title),
                      onTap: () => Navigator.pop(context, s),
                    );
                  },
                ),
    );
  }
}

class _SearchPicker extends StatefulWidget {
  const _SearchPicker({required this.source});
  final DownloadSource source;

  @override
  State<_SearchPicker> createState() => _SearchPickerState();
}

class _SearchPickerState extends State<_SearchPicker> {
  final _controller = TextEditingController();
  List<RemoteTrack>? _results;
  bool _loading = false;
  bool _failed = false;
  int _gen = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = sanitizeSearchInput(_controller.text);
    if (q.isEmpty) return;
    final gen = ++_gen;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final r = await widget.source.search(q, limit: 20);
      if (!mounted || gen != _gen) return;
      setState(() => _results = r);
    } catch (e) {
      print('Mix: falló la búsqueda (${e.runtimeType})');
      if (mounted && gen == _gen) setState(() => _failed = true);
    } finally {
      if (mounted && gen == _gen) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final results = _results;
    return _PickerFrame(
      title: l10n.mixerPickSearch,
      field: TextField(
        key: const Key('mixer_search_field'),
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.search,
        onSubmitted: (_) => _search(),
        decoration: _fieldDecoration(l10n.mixerPickerSearchHint).copyWith(
          suffixIcon: IconButton(icon: const Icon(Icons.search_rounded, color: Colors.white70), onPressed: _search),
        ),
        style: const TextStyle(color: Colors.white),
      ),
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : _failed
              ? _Empty(l10n.mixerPickerSearchFailed)
              : results == null
                  ? const SizedBox.shrink()
                  : results.isEmpty
                      ? _Empty(l10n.mixerPickerEmpty)
                      : ListView.builder(
                          itemCount: results.length,
                          itemBuilder: (_, i) {
                            final t = results[i];
                            return _PickerRow(
                              title: t.title,
                              subtitle: t.artist,
                              leading: MixerArt(url: t.thumbnailUrl, title: t.title),
                              onTap: () => Navigator.pop(context, t),
                            );
                          },
                        ),
    );
  }
}

InputDecoration _fieldDecoration(String hint) => InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.08),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
    );

class _PickerFrame extends StatelessWidget {
  const _PickerFrame({required this.title, required this.field, required this.child});
  final String title;
  final Widget field;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(kScreenGutter, 20, kScreenGutter, 12),
              child: Text(title, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
            ),
            Padding(padding: const EdgeInsets.symmetric(horizontal: kScreenGutter), child: field),
            const SizedBox(height: 8),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

class _PickerRow extends StatelessWidget {
  const _PickerRow({required this.title, required this.subtitle, required this.leading, required this.onTap});
  final String title, subtitle;
  final Widget leading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
        leading: ClipRRect(borderRadius: BorderRadius.circular(8), child: leading),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white)),
        subtitle: Text(subtitle,
            maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.white.withValues(alpha: 0.5))),
        onTap: onTap,
      );
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(text, textAlign: TextAlign.center, style: TextStyle(color: Colors.white.withValues(alpha: 0.6))),
        ),
      );
}

/// Carátula de la biblioteca o el degradado del título.
class MixerArt extends StatelessWidget {
  const MixerArt({super.key, this.path = '', this.url = '', required this.title, this.size = 48});
  final String path, url, title;
  final double size;

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(gradient: AppTheme.gradientForTitle(title)),
      child: Icon(Icons.music_note_rounded, color: Colors.white70, size: size * 0.45),
    );
    if (path.isNotEmpty && File(path).existsSync()) {
      return Image.file(File(path), width: size, height: size, fit: BoxFit.cover, errorBuilder: (_, __, ___) => placeholder);
    }
    final uri = Uri.tryParse(url);
    if (uri != null && uri.scheme == 'https') {
      return Image.network(url, width: size, height: size, fit: BoxFit.cover, errorBuilder: (_, __, ___) => placeholder);
    }
    return placeholder;
  }
}
