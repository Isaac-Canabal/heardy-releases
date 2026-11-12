// Carril interactivo del editor de Heardy Mixer (bloques con título que se
// arrastran, se acortan y reciben trozos soltados) y la escucha del resultado
// sin salir del editor. La geometría es pura y vive en `mix_waveform_painter.dart`.
import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/mix_record.dart';
import '../services/audio_player_handler.dart';
import '../services/mix/mix_edit_plan.dart';
import '../services/mix/mix_types.dart';
import '../services/mix/mixer_labels.dart';
import '../services/mix/mixer_logic.dart' show mixMediaItem;
import 'mix_waveform_painter.dart';

/// Texto corto de un bloque, para dibujarlo dentro ("Voz · Thunder").
String mixBlockLabel(AppLocalizations l10n, MixEditSegment s, Map<String, String> titles) {
  final title = shortSongTitle(titles[s.song] ?? '', max: 22, fallback: s.song.toUpperCase());
  return switch (mixBlockKind(s.layer)) {
    MixBlockKind.voice => l10n.editorBlockVoice(title),
    MixBlockKind.music => l10n.editorBlockMusic(title),
    MixBlockKind.both => l10n.editorBlockBoth(title),
  };
}

/// Frase de un bloque ("Voz de «Thunder»").
String mixBlockSentence(AppLocalizations l10n, MixEditSegment s, Map<String, String> titles) {
  final title = shortSongTitle(titles[s.song] ?? '', fallback: s.song.toUpperCase());
  return switch (mixBlockKind(s.layer)) {
    MixBlockKind.voice => l10n.editorBlockVoiceLong(title),
    MixBlockKind.music => l10n.editorBlockMusicLong(title),
    MixBlockKind.both => l10n.editorBlockBothLong(title),
  };
}

/// "Empieza en 0:16 · dura 0:19".
String mixBlockWhen(AppLocalizations l10n, MixEditSegment s, double tempoBpm) =>
    l10n.editorBlockWhen(barTime(s.outBar, tempoBpm), clockText(s.bars * barSeconds(tempoBpm)));

/// Estado de la escucha: qué suena, por dónde va y si está sonando.
class MixPreviewTick {
  const MixPreviewTick({required this.mediaId, required this.position, required this.playing});
  final String? mediaId;
  final Duration position;
  final bool playing;
}

/// Lo que el editor necesita del reproductor para escuchar un mix en el sitio.
/// Existe para que la pantalla se pueda probar sin el reproductor real.
abstract class MixPreviewPlayer {
  Stream<MixPreviewTick> get ticks;
  Future<void> play(MixRecord record);
  Future<void> pause();
  Future<void> resume();
  Future<void> seek(Duration position);
  void dispose();
}

String mixPreviewMediaId(MixRecord r) => mixMediaItem(r).id;

/// [MixPreviewPlayer] sobre el reproductor de la app: el mix suena como un
/// elemento efímero `mix:` ([AudioPlayerHandler.playEphemeralFile]).
class HandlerMixPreviewPlayer implements MixPreviewPlayer {
  HandlerMixPreviewPlayer(this._handler) {
    _controller = StreamController<MixPreviewTick>.broadcast(onListen: _listen, onCancel: _cancel);
  }

  final AudioPlayerHandler _handler;
  late final StreamController<MixPreviewTick> _controller;
  final List<StreamSubscription<Object?>> _subs = [];

  void _emit([Object? _]) {
    if (_controller.isClosed) return;
    final player = _handler.player;
    _controller.add(
        MixPreviewTick(mediaId: _handler.mediaItem.value?.id, position: player.position, playing: player.playing));
  }

  void _listen() {
    final player = _handler.player;
    _subs.addAll([
      player.positionStream.listen(_emit),
      player.playingStream.listen(_emit),
      _handler.mediaItem.listen(_emit),
    ]);
  }

  void _cancel() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
  }

  @override
  Stream<MixPreviewTick> get ticks => _controller.stream;
  @override
  Future<void> play(MixRecord record) => _handler.playEphemeralFile(mixMediaItem(record), record.filePath);
  @override
  Future<void> pause() => _handler.pause();
  @override
  Future<void> resume() => _handler.play();
  @override
  Future<void> seek(Duration position) => _handler.seek(position);
  @override
  void dispose() {
    _cancel();
    _controller.close();
  }
}

/// Un trozo de canción que se arrastra desde su onda hasta el mix.
class MixFragmentDrag {
  const MixFragmentDrag({required this.song, required this.layer, required this.fromBar, required this.bars});
  final String song;
  final MixLayer layer;
  final int fromBar, bars;
}

/// De quién es cada color y qué fila es la voz, con palabras.
class MixEditorLegend extends StatelessWidget {
  const MixEditorLegend({super.key, required this.titles});
  final Map<String, String> titles;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    Widget song(String id) => Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 12, height: 12, decoration: BoxDecoration(color: mixSongColor(id), shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Flexible(
            child: Text(l10n.editorSongLane(shortSongTitle(titles[id] ?? '', fallback: id.toUpperCase())),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: mixSongColor(id), fontWeight: FontWeight.w700)),
          ),
        ]);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 16, runSpacing: 4, children: [song('a'), song('b')]),
      const SizedBox(height: 2),
      Text(l10n.editorLegendRows, style: const TextStyle(color: Colors.white60, fontSize: 12)),
    ]);
  }
}

/// El mix como bloques de color con título. Tocar elige un bloque y marca el
/// punto; arrastrar el cuerpo lo mueve y arrastrar un borde lo acorta o alarga
/// (pegado a la rejilla); soltar encima un [MixFragmentDrag] lo añade ahí.
class MixBlocksLane extends StatefulWidget {
  const MixBlocksLane({
    super.key,
    required this.segments,
    required this.totalBars,
    required this.labels,
    required this.onTap,
    this.selectedIndex = -1,
    this.cursorBar,
    this.playheadBar,
    this.onDragStart,
    this.onMove,
    this.onResizeStart,
    this.onResizeEnd,
    this.onDragEnd,
    this.onDropFragment,
    this.height = 96,
  });

  final List<MixEditSegment> segments;
  final int totalBars;
  final List<String> labels;
  final int selectedIndex;
  final int? cursorBar;
  final double? playheadBar;
  final double height;

  /// Compás tocado y bloque que hay ahí (-1 si ninguno).
  final void Function(int bar, int index) onTap;

  /// Empieza un arrastre sobre el bloque [index].
  final void Function(int index)? onDragStart;

  /// El bloque [index] debe empezar en [outBar] (sin acotar).
  final void Function(int index, int outBar)? onMove;

  /// El borde izquierdo / derecho del bloque [index] va a la línea [bar].
  final void Function(int index, int bar)? onResizeStart, onResizeEnd;
  final VoidCallback? onDragEnd;

  /// Se soltó un trozo de canción en la línea [bar].
  final void Function(MixFragmentDrag fragment, int bar)? onDropFragment;

  @override
  State<MixBlocksLane> createState() => _MixBlocksLaneState();
}

class _MixBlocksLaneState extends State<MixBlocksLane> {
  ({int index, MixBlockPart part})? _hit;
  double _grabX = 0;
  int _startOutBar = 0;
  bool _dragging = false;

  void _down(Offset pos, Size size) {
    final hit = hitTestBlock(widget.segments, widget.totalBars, size, pos);
    _hit = hit.index < 0 ? null : hit;
    _grabX = pos.dx;
    if (hit.index >= 0) _startOutBar = widget.segments[hit.index].outBar;
  }

  void _update(Offset pos, double width) {
    final hit = _hit;
    if (hit == null || hit.index >= widget.segments.length) return;
    if (!_dragging) {
      _dragging = true;
      widget.onDragStart?.call(hit.index);
    }
    switch (hit.part) {
      case MixBlockPart.body:
        widget.onMove?.call(
            hit.index,
            dragTargetBar(
                startOutBar: _startOutBar, grabX: _grabX, x: pos.dx, totalBars: widget.totalBars, width: width));
      case MixBlockPart.start:
        widget.onResizeStart?.call(hit.index, xToSnappedBar(pos.dx, widget.totalBars, width));
      case MixBlockPart.end:
        widget.onResizeEnd?.call(hit.index, xToSnappedBar(pos.dx, widget.totalBars, width));
    }
  }

  void _end() {
    if (_dragging) widget.onDragEnd?.call();
    _dragging = false;
    _hit = null;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final size = Size(c.maxWidth, widget.height);
      return DragTarget<MixFragmentDrag>(
        onWillAcceptWithDetails: (_) => widget.onDropFragment != null,
        onAcceptWithDetails: (d) {
          final box = context.findRenderObject() as RenderBox?;
          if (box == null) return;
          final local = box.globalToLocal(d.offset);
          widget.onDropFragment?.call(d.data, xToSnappedBar(local.dx, widget.totalBars, size.width));
        },
        builder: (context, candidates, _) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) => widget.onTap(xToBar(d.localPosition.dx, widget.totalBars, size.width),
              hitTestBlock(widget.segments, widget.totalBars, size, d.localPosition).index),
          onHorizontalDragDown: (d) => _down(d.localPosition, size),
          onHorizontalDragUpdate: (d) => _update(d.localPosition, size.width),
          onHorizontalDragEnd: (_) => _end(),
          onHorizontalDragCancel: _end,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0x22FFFFFF),
                border: candidates.isNotEmpty ? Border.all(color: Colors.white, width: 2) : null,
              ),
              child: CustomPaint(
                size: size,
                painter: MixResultLanePainter(
                  segments: widget.segments,
                  totalBars: widget.totalBars,
                  selectedIndex: widget.selectedIndex,
                  cursorBar: widget.cursorBar,
                  labels: widget.labels,
                  playheadBar: widget.playheadBar,
                ),
              ),
            ),
          ),
        ),
      );
    });
  }
}
