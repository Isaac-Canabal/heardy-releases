const double minPlaybackRate = 0.5;
const double maxPlaybackRate = 2.0;
const double playbackRateStep = 0.05;

const List<double> playbackSpeedPresets = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

/// Acota a [minPlaybackRate, maxPlaybackRate] y ajusta al paso del slider.
double normalizePlaybackRate(double value) {
  if (value.isNaN || value.isInfinite) return 1.0;
  final clamped = value.clamp(minPlaybackRate, maxPlaybackRate).toDouble();
  final snapped = (clamped / playbackRateStep).round() * playbackRateStep;
  return double.parse(snapped.toStringAsFixed(2));
}

String playbackRateLabel(double rate) {
  var text = rate.toStringAsFixed(2);
  if (text.contains('.')) {
    text = text.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  }
  return '${text}x';
}

bool isDefaultPlayback(double speed, double pitch) =>
    (speed - 1.0).abs() < 0.001 && (pitch - 1.0).abs() < 0.001;
