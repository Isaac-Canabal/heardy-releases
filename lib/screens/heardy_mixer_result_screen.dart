import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/mix_record.dart';
import '../providers/heardy_mixer_provider.dart';
import '../services/audio_player_handler.dart';
import '../services/mix/mix_types.dart' show MixWarning;
import '../services/mix/mix_naming.dart';
import '../services/mix/mixer_labels.dart';
import '../services/mix/mixer_logic.dart';
import '../theme/app_theme.dart';
import '../widgets/desktop_shell_scope.dart';
import '../widgets/max_width_center.dart';
import 'heardy_mixer_screen.dart' show MixerStyleCard, MixerWarningsCard;

typedef MixesSectionOpener = void Function(BuildContext context, MixRecord record);

/// Resultado de un mix: escucharlo sin guardarlo, renombrarlo e ir a Mixes.
class HeardyMixerResultScreen extends StatefulWidget {
  const HeardyMixerResultScreen({super.key, required this.record, this.play});

  final MixRecord record;

  /// Reproducción efímera; por defecto [AudioPlayerHandler.playEphemeralFile].
  final Future<void> Function(MixRecord record)? play;

  /// La sección Mixes de Explorar se asigna aquí al arrancar
  /// (`registerMixesSection`). Sin ella, "Ver en Mixes" solo avisa.
  static MixesSectionOpener? openMixes;

  @override
  State<HeardyMixerResultScreen> createState() => _HeardyMixerResultScreenState();
}

class _HeardyMixerResultScreenState extends State<HeardyMixerResultScreen> {
  late final TextEditingController _name;
  bool _playing = false;

  MixRecord get _record {
    final last = context.read<HeardyMixerProvider>().lastRecord;
    return last != null && last.id == widget.record.id ? last : widget.record;
  }

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.record.name);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _play() async {
    if (_playing) return;
    final r = _record;
    setState(() => _playing = true);
    try {
      final play = widget.play ??
          (MixRecord r) => context.read<AudioPlayerHandler>().playEphemeralFile(mixMediaItem(r), r.filePath);
      DesktopShellScope.maybeOf(context)?.openNowPlaying();
      await play(r);
    } catch (e) {
      print('Mix: no se pudo reproducir el mix (${e.runtimeType})');
      if (mounted) _snack(AppLocalizations.of(context)!.mixerResultPlayFailed);
    } finally {
      if (mounted) setState(() => _playing = false);
    }
  }

  Future<void> _rename() async {
    FocusScope.of(context).unfocus();
    final mixer = context.read<HeardyMixerProvider>();
    if (mixer.lastRecord?.id != widget.record.id) return;
    await mixer.rename(_name.text);
    if (!mounted) return;
    _name.text = _record.name;
    _snack(AppLocalizations.of(context)!.mixerResultRenamed);
  }

  void _openMixes() {
    final open = HeardyMixerResultScreen.openMixes;
    if (open != null) {
      open(context, _record);
    } else {
      _snack(AppLocalizations.of(context)!.mixerResultMixesSoon);
    }
  }

  void _snack(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    context.watch<HeardyMixerProvider>();
    final r = _record;
    final mixer = context.read<HeardyMixerProvider>();
    final warnings = mixer.lastRecord?.id == r.id ? mixer.lastWarnings : const <MixWarning>[];
    final report = mixer.lastRecord?.id == r.id ? mixer.lastReport : null;
    final art = r.artPath.isNotEmpty && File(r.artPath).existsSync() ? File(r.artPath) : null;
    return Scaffold(
      body: Container(
        decoration: AppTheme.gradientScaffold(),
        child: SafeArea(
          child: MaxWidthCenter(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(kScreenGutter, 8, kScreenGutter, 24),
              children: [
                Row(children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  Text(l10n.mixerResultTitle,
                      style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800)),
                ]),
                const SizedBox(height: 16),
                Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: SizedBox.square(
                      dimension: 220,
                      child: art != null
                          ? Image.file(art, fit: BoxFit.cover)
                          : DecoratedBox(
                              decoration: BoxDecoration(gradient: AppTheme.gradientForTitle(r.name)),
                              child: const Icon(Icons.multitrack_audio_rounded, color: Colors.white70, size: 72),
                            ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                TextField(
                  key: const Key('mixer_result_name'),
                  controller: _name,
                  maxLength: 80,
                  style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
                  decoration: InputDecoration(
                    labelText: l10n.mixerResultName,
                    labelStyle: const TextStyle(color: Colors.white60),
                    suffixIcon: IconButton(
                      key: const Key('mixer_result_rename'),
                      tooltip: l10n.mixerResultRename,
                      icon: const Icon(Icons.check_rounded, color: Colors.white),
                      onPressed: _rename,
                    ),
                  ),
                  onSubmitted: (_) => _rename(),
                ),
                Text(
                  '${combinedMixArtist(r.artistA, r.artistB)} · ${AppTheme.formatDuration(r.durationMs ~/ 1000)}',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
                ),
                const SizedBox(height: 20),
                AppTheme.gradientButton(
                  onPressed: _playing ? null : _play,
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.play_arrow_rounded, color: Colors.white),
                    const SizedBox(width: 6),
                    Text(l10n.mixerResultPlay,
                        key: const Key('mixer_result_play'),
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                  ]),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  key: const Key('mixer_result_view_mixes'),
                  onPressed: _openMixes,
                  icon: const Icon(Icons.queue_music_rounded),
                  label: Text(l10n.mixerResultViewMixes),
                ),
                if (mixer.lastFromEditor && mixer.lastRecord?.id == r.id)
                  TextButton.icon(
                    key: const Key('mixer_result_back_to_editor'),
                    onPressed: () {
                      mixer.backToEditing();
                      Navigator.of(context).maybePop();
                    },
                    icon: const Icon(Icons.tune_rounded),
                    label: Text(l10n.editorBackToEditor),
                  ),
                if (report?.selection != null) ...[
                  const SizedBox(height: 12),
                  MixerStyleCard(report: report!),
                ],
                if (warnings.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  MixerWarningsCard(warnings: warnings, titleA: shortSongTitle(r.titleA), titleB: shortSongTitle(r.titleB)),
                ],
                const SizedBox(height: 12),
                Text(l10n.mixerResultLocalNote,
                    textAlign: TextAlign.center, style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 12)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
