import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/ui/voice/recording_envelope.dart';

void main() {
  test('one word rises smoothly and returns to silence without latching', () {
    final envelope = RecordingEnvelope();
    final first = envelope.advance(1, 1 / 60);
    expect(first, inExclusiveRange(0, 0.2));
    for (var i = 0; i < 30; i++) { envelope.advance(0.8, 1 / 60); }
    expect(envelope.value, greaterThan(0.5));
    for (var i = 0; i < 120; i++) { envelope.advance(0, 1 / 60); }
    expect(envelope.value, lessThan(0.003));
  });

  test('envelope is independent of screen refresh rate', () {
    final a = RecordingEnvelope();
    final b = RecordingEnvelope();
    for (var i = 0; i < 60; i++) { a.advance(0.6, 1 / 60); }
    for (var i = 0; i < 120; i++) { b.advance(0.6, 1 / 120); }
    expect(a.value, closeTo(b.value, 0.00001));
  });
}
