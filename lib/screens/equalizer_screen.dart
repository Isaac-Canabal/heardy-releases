import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../services/audio_effects_service.dart';
import '../services/equalizer.dart';
import '../theme/app_theme.dart';
import '../widgets/max_width_center.dart';

/// `1000` -> `1k`, `16000` -> `16k`, `500` -> `500`.
String equalizerBandLabel(int hz) => hz >= 1000 ? '${hz ~/ 1000}k' : '$hz';

/// `+3.5`, `0`, `-12`.
String formatEqualizerDb(double db) {
  final v = (db * 10).round() / 10;
  if (v == 0) return '0';
  final text = v == v.truncateToDouble() ? v.toInt().toString() : v.toString();
  return v > 0 ? '+$text' : text;
}

String equalizerPresetLabel(AppLocalizations l10n, EqualizerPreset preset) => switch (preset) {
      EqualizerPreset.plano => l10n.equalizerPresetPlano,
      EqualizerPreset.graves => l10n.equalizerPresetGraves,
      EqualizerPreset.voces => l10n.equalizerPresetVoces,
      EqualizerPreset.rock => l10n.equalizerPresetRock,
      EqualizerPreset.pop => l10n.equalizerPresetPop,
      EqualizerPreset.electronica => l10n.equalizerPresetElectronica,
      EqualizerPreset.acustico => l10n.equalizerPresetAcustico,
      EqualizerPreset.clasica => l10n.equalizerPresetClasica,
      EqualizerPreset.hipHop => l10n.equalizerPresetHipHop,
      EqualizerPreset.agudos => l10n.equalizerPresetAgudos,
      EqualizerPreset.personalizado => l10n.equalizerPresetPersonalizado,
    };

class EqualizerScreen extends StatelessWidget {
  const EqualizerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final fx = context.watch<AudioEffectsService>();
    final enabled = fx.equalizerEnabled;
    final preamp = equalizerPreampDb(fx.equalizerGains);
    final dimText = Colors.white.withValues(alpha: 0.45);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(l10n.equalizerTitle),
        backgroundColor: Colors.transparent,
        actions: [
          TextButton(
            key: const Key('equalizer_reset'),
            onPressed: fx.resetEqualizer,
            child: Text(l10n.equalizerReset),
          ),
        ],
      ),
      body: Container(
        decoration: AppTheme.gradientScaffold(),
        child: MaxWidthCenter(
          maxWidth: 720,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(kScreenGutter, 8, kScreenGutter, 32),
            children: [
              Container(
                decoration: AppTheme.glassCard(),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Material(
                  type: MaterialType.transparency,
                  child: SwitchListTile(
                    key: const Key('equalizer_switch'),
                    contentPadding: EdgeInsets.zero,
                    activeThumbColor: AppTheme.primaryLight,
                    value: enabled,
                    title: Text(l10n.equalizerEnable, style: const TextStyle(color: Colors.white, fontSize: 14)),
                    onChanged: fx.setEqualizerEnabled,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // `Wrap`, no una fila desplazable: en Windows el ratón no
              // arrastra un scroll horizontal y los preajustes del final
              // quedaban inalcanzables.
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final preset in EqualizerPreset.values)
                    if (preset != EqualizerPreset.personalizado || fx.equalizerPreset == preset)
                      ChoiceChip(
                        key: Key('equalizer_preset_${preset.name}'),
                        label: Text(equalizerPresetLabel(l10n, preset)),
                        selected: fx.equalizerPreset == preset,
                        selectedColor: AppTheme.primary,
                        onSelected: enabled ? (_) => fx.selectEqualizerPreset(preset) : null,
                      ),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                decoration: AppTheme.glassCard(),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                child: _EqualizerBands(
                  gains: fx.equalizerGains,
                  enabled: enabled,
                  onChanged: fx.setEqualizerBand,
                ),
              ),
              if (enabled && preamp < 0) ...[
                const SizedBox(height: 12),
                Text(l10n.equalizerPreamp(formatEqualizerDb(preamp)), style: TextStyle(color: dimText, fontSize: 12)),
              ],
              const SizedBox(height: 12),
              Text(l10n.equalizerHelp, style: TextStyle(color: dimText, fontSize: 12, height: 1.4)),
            ],
          ),
        ),
      ),
    );
  }
}

class _EqualizerBands extends StatelessWidget {
  final List<double> gains;
  final bool enabled;
  final void Function(int index, double db) onChanged;

  const _EqualizerBands({required this.gains, required this.enabled, required this.onChanged});

  static const _scaleWidth = 28.0;
  static const _minBandWidth = 32.0;
  static const _sliderHeight = 200.0;

  @override
  Widget build(BuildContext context) {
    final valueStyle = TextStyle(
      color: enabled ? Colors.white : Colors.white38,
      fontSize: 11,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    const labelStyle = TextStyle(color: Colors.white54, fontSize: 11);
    final scaleStyle = TextStyle(color: Colors.white.withValues(alpha: 0.35), fontSize: 10);

    return LayoutBuilder(builder: (context, constraints) {
      final count = equalizerBandsHz.length;
      final bandWidth =
          ((constraints.maxWidth - _scaleWidth) / count).clamp(_minBandWidth, 72.0).toDouble();
      final row = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: _scaleWidth,
            child: Padding(
              padding: const EdgeInsets.only(top: 18),
              child: SizedBox(
                height: _sliderHeight,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('+12', style: scaleStyle),
                    Text('0', style: scaleStyle),
                    Text('-12', style: scaleStyle),
                  ],
                ),
              ),
            ),
          ),
          for (var i = 0; i < count; i++)
            SizedBox(
              width: bandWidth,
              child: Column(
                children: [
                  SizedBox(
                    height: 18,
                    child: Text(formatEqualizerDb(gains[i]), style: valueStyle),
                  ),
                  SizedBox(
                    height: _sliderHeight,
                    child: RotatedBox(
                      quarterTurns: 3,
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                          overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                          activeTrackColor: AppTheme.primaryLight,
                          thumbColor: AppTheme.primaryLight,
                          inactiveTrackColor: Colors.white24,
                        ),
                        child: Slider(
                          key: Key('equalizer_band_$i'),
                          value: gains[i].clamp(equalizerMinDb, equalizerMaxDb).toDouble(),
                          min: equalizerMinDb,
                          max: equalizerMaxDb,
                          divisions: ((equalizerMaxDb - equalizerMinDb) / equalizerStepDb).round(),
                          onChanged: enabled ? (v) => onChanged(i, v) : null,
                          onChangeEnd: enabled ? (v) => onChanged(i, v) : null,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(equalizerBandLabel(equalizerBandsHz[i]), style: labelStyle),
                ],
              ),
            ),
        ],
      );
      final needed = _scaleWidth + bandWidth * count;
      if (needed <= constraints.maxWidth) return Center(child: row);
      return _MouseDraggableScroll(child: row);
    });
  }
}

/// Desplazamiento horizontal que también arrastra el ratón y muestra la barra:
/// el `ScrollBehavior` por defecto sólo arrastra con el dedo.
class _MouseDraggableScroll extends StatefulWidget {
  final Widget child;

  const _MouseDraggableScroll({required this.child});

  @override
  State<_MouseDraggableScroll> createState() => _MouseDraggableScrollState();
}

class _MouseDraggableScrollState extends State<_MouseDraggableScroll> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(dragDevices: PointerDeviceKind.values.toSet()),
      child: Scrollbar(
        controller: _controller,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: _controller,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.only(bottom: 10),
          child: widget.child,
        ),
      ),
    );
  }
}
