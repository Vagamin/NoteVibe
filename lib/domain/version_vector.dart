import 'dart:convert';

/// Result of comparing two version vectors.
enum VvOrder { equal, before, after, concurrent }

/// Version vector: per-device edit counters. Used to detect whether one
/// version of a note descends from another or both were edited concurrently.
class VersionVector {
  final Map<String, int> _clock;

  const VersionVector._(this._clock);

  VersionVector([Map<String, int>? clock])
      : _clock = Map.unmodifiable(
            Map.fromEntries((clock ?? const {}).entries.where((e) => e.value > 0)));

  static const empty = VersionVector._({});

  Map<String, int> get entries => _clock;

  int operator [](String device) => _clock[device] ?? 0;

  VersionVector increment(String device) =>
      VersionVector({..._clock, device: this[device] + 1});

  VersionVector merge(VersionVector other) {
    final result = Map<String, int>.from(_clock);
    other._clock.forEach((k, v) {
      if (v > (result[k] ?? 0)) result[k] = v;
    });
    return VersionVector(result);
  }

  VvOrder compare(VersionVector other) {
    var less = false;
    var greater = false;
    for (final key in {..._clock.keys, ...other._clock.keys}) {
      final a = this[key];
      final b = other[key];
      if (a < b) less = true;
      if (a > b) greater = true;
      if (less && greater) return VvOrder.concurrent;
    }
    if (less) return VvOrder.before;
    if (greater) return VvOrder.after;
    return VvOrder.equal;
  }

  /// True if this vector is less than or equal to [other] (already included).
  bool isDominatedBy(VersionVector other) {
    final c = compare(other);
    return c == VvOrder.before || c == VvOrder.equal;
  }

  /// Canonical encoding (sorted keys) — usable as a stable identifier.
  String encode() {
    final keys = _clock.keys.toList()..sort();
    return jsonEncode({for (final k in keys) k: _clock[k]});
  }

  static VersionVector decode(String? json) {
    if (json == null || json.isEmpty) return VersionVector.empty;
    final map = (jsonDecode(json) as Map).map((k, v) => MapEntry(k as String, (v as num).toInt()));
    return VersionVector(map);
  }

  Map<String, dynamic> toJson() => Map<String, dynamic>.from(_clock);

  static VersionVector fromJson(Object? json) {
    if (json is! Map) return VersionVector.empty;
    return VersionVector(json.map((k, v) => MapEntry(k as String, (v as num).toInt())));
  }

  @override
  bool operator ==(Object other) =>
      other is VersionVector && compare(other) == VvOrder.equal;

  @override
  int get hashCode {
    final keys = _clock.keys.toList()..sort();
    return Object.hashAll(keys.map((k) => '$k=${_clock[k]}'));
  }

  @override
  String toString() => 'VV$_clock';
}
