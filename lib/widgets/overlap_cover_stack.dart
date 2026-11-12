import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/overlap_view.dart';

/// Cover that follows what is heard. Steady state: one cover. While two songs
/// overlap, both covers show together (outgoing steps back and left, incoming
/// enters from the right like a card stack, opacity following the audible
/// gains); when the overlap ends the outgoing cover shrinks away and the
/// incoming one settles at full size. Purely visual: it only reads [overlap].
///
/// Interruptible: any change of [overlap] or [item] retargets the animation,
/// and a cancelled overlap settles on the real current item with no stuck
/// state. With reduced motion the covers only cross-fade, without movement.
class OverlapCoverStack extends StatefulWidget {
  const OverlapCoverStack({
    super.key,
    required this.item,
    required this.overlap,
    required this.size,
    required this.coverBuilder,
  });

  /// Real current item of the player.
  final MediaItem item;
  final ValueListenable<OverlapView?> overlap;
  final double size;
  final Widget Function(BuildContext context, MediaItem item) coverBuilder;

  @override
  State<OverlapCoverStack> createState() => _OverlapCoverStackState();
}

class _OverlapCoverStackState extends State<OverlapCoverStack> with SingleTickerProviderStateMixin {
  // 0 = settled before the overlap, 1 = both covers together, 2 = settled after.
  late final AnimationController _c = AnimationController(
    vsync: this,
    lowerBound: 0,
    upperBound: 2,
    value: 0,
  );

  late MediaItem _in;
  MediaItem? _out;
  bool _leaving = false;
  OverlapView? _view;

  static const _enterDuration = Duration(milliseconds: 450);
  static const _leaveDuration = Duration(milliseconds: 500);

  @override
  void initState() {
    super.initState();
    _in = widget.item;
    _view = widget.overlap.value;
    widget.overlap.addListener(_onOverlap);
    _c.addStatusListener(_onStatus);
    _retarget();
  }

  @override
  void didUpdateWidget(OverlapCoverStack old) {
    super.didUpdateWidget(old);
    if (old.overlap != widget.overlap) {
      old.overlap.removeListener(_onOverlap);
      widget.overlap.addListener(_onOverlap);
      _view = widget.overlap.value;
    }
    _retarget();
  }

  @override
  void dispose() {
    widget.overlap.removeListener(_onOverlap);
    _c.dispose();
    super.dispose();
  }

  void _onOverlap() {
    if (!mounted) return;
    setState(() {
      _view = widget.overlap.value;
      _retarget();
    });
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && _c.value >= 2 && _out != null && mounted) {
      setState(() {
        _out = null;
        _leaving = false;
        _c.value = 0;
      });
    }
  }

  /// Moves the animation toward what the current inputs say should be on screen.
  void _retarget() {
    final v = _view;
    if (v != null && (v.phase == OverlapPhase.enter || v.phase == OverlapPhase.both)) {
      _showPair(v.outgoing, v.incoming);
    } else {
      final MediaItem target = v == null
          ? widget.item
          : (v.phase == OverlapPhase.pre ? v.outgoing : v.incoming);
      _showSingle(target);
    }
  }

  void _showPair(MediaItem outgoing, MediaItem incoming) {
    if (_out != null && _out!.id == outgoing.id && _in.id == incoming.id && !_leaving) return;
    _out = outgoing;
    _in = incoming;
    _leaving = false;
    _c.stop();
    _c.value = 0;
    _c.animateTo(1, duration: _enterDuration, curve: Curves.easeOutCubic);
  }

  void _showSingle(MediaItem target) {
    if (_out == null) {
      _in = target;
      return;
    }
    if (target.id == _in.id) {
      if (_leaving) return;
      _leaving = true;
      _c.animateTo(2, duration: _leaveDuration, curve: Curves.easeInOutCubic);
    } else {
      _c.stop();
      _out = null;
      _in = target;
      _leaving = false;
      _c.value = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final out = _out;
    if (out == null) {
      return SizedBox(
        width: size,
        height: size,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: KeyedSubtree(
            key: ValueKey<String>('overlap-single-${_in.id}'),
            child: SizedBox(width: size, height: size, child: widget.coverBuilder(context, _in)),
          ),
        ),
      );
    }
    final move = !MediaQuery.disableAnimationsOf(context);
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final e = _c.value.clamp(0.0, 1.0);
        final l = math.max(0.0, _c.value - 1).clamp(0.0, 1.0);
        final progress = _leaving ? 1.0 : (_view?.progress ?? 0.0).clamp(0.0, 1.0);
        final outOpacity = (1 - 0.5 * progress) * (1 - l);
        final inOpacity = (0.5 + 0.5 * progress) * e + (1 - (0.5 + 0.5 * progress) * e) * l;
        return SizedBox(
          width: size,
          height: size,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              _layer(
                key: const ValueKey('overlap-cover-out'),
                item: out,
                opacity: outOpacity,
                scale: move ? _lerp(_lerp(1, 0.84, e), 0.6, l) : 1,
                dx: move ? -0.14 * size * e - 0.10 * size * l : 0,
                angle: move ? -0.06 * e * (1 - l) : 0,
              ),
              _layer(
                key: const ValueKey('overlap-cover-in'),
                item: _in,
                opacity: inOpacity,
                scale: move ? _lerp(_lerp(0.9, 0.92, e), 1, l) : 1,
                dx: move ? _lerp(0.5 * size * (1 - e) + 0.14 * size * e, 0, l) : 0,
                angle: move ? 0.05 * e * (1 - l) : 0,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _layer({
    required Key key,
    required MediaItem item,
    required double opacity,
    required double scale,
    required double dx,
    required double angle,
  }) {
    return Positioned.fill(
      key: key,
      child: Opacity(
        opacity: opacity.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(dx, 0),
          child: Transform.rotate(
            angle: angle,
            child: Transform.scale(
              scale: scale,
              child: widget.coverBuilder(context, item),
            ),
          ),
        ),
      ),
    );
  }
}

double _lerp(double a, double b, double t) => a + (b - a) * t;
