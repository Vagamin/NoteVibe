import 'dart:math' as math;

/// Time-based smoothing, independent of the display refresh rate.
class RecordingEnvelope {
  double value = 0;

  double advance(double level, double seconds) {
    final input = level.clamp(0.0, 1.0);
    final target = input * input * (3 - 2 * input);
    final tau = target > value ? 0.14 : 0.32;
    value += (target - value) * (1 - math.exp(-seconds.clamp(0.0, 0.1) / tau));
    return value;
  }
}
