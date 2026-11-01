import 'dart:convert';
import 'dart:typed_data';

import 'package:notevibe/data/note_store.dart';
import 'package:notevibe/sync/crypto/keys.dart';
import 'package:notevibe/sync/crypto/secure_channel.dart';
import 'package:notevibe/sync/engine/sync_engine.dart';
import 'package:notevibe/sync/transport/frame_channel.dart';

class FakeClock {
  DateTime t;
  FakeClock([DateTime? start]) : t = start ?? DateTime(2026, 1, 1, 12);
  DateTime call() => t = t.add(const Duration(seconds: 1));
}

class TestPolicy extends HandshakePolicy {
  final Map<String, Uint8List> keys;
  List<int>? qrToken;
  String? code;
  int failures = 0;
  TestPolicy({Map<String, Uint8List>? keys}) : keys = keys ?? {};

  @override
  Future<Uint8List?> peerKey(String deviceId) async => keys[deviceId];

  @override
  List<int>? pairingSecret(HandshakeMode mode) => switch (mode) {
        HandshakeMode.pairQr => qrToken,
        HandshakeMode.pairCode => code == null ? null : utf8.encode(code!),
        HandshakeMode.sync => null,
      };

  @override
  void onPairingFailure() => failures++;
}

/// A simulated device: store + identity.
class Device {
  final String id;
  final NoteStore store;
  final DeviceIdentity identity;
  Device._(this.id, this.store, this.identity);

  static Future<Device> create(String id, {FakeClock? clock}) async {
    final store = NoteStore.inMemory(deviceId: id, now: (clock ?? FakeClock()).call);
    final ident = await DeviceIdentity.fromSeed(id, 'Device $id', List.filled(32, id.codeUnitAt(0)));
    return Device._(id, store, ident);
  }

  void trust(Device other) => store.upsertPeer(
      deviceId: other.id, name: other.identity.name, publicKey: other.identity.publicKey);
}

/// Pairs two devices in the store and runs a full encrypted sync session
/// over an in-memory channel. [dropAfter] makes initiator's channel fail
/// after sending that many frames.
Future<(SyncStats, SyncStats)> syncPair(Device a, Device b, {int? dropAfter}) async {
  final (ca, cb) = MemoryFrameChannel.pair();
  ca.dropAfter = dropAfter;
  final policy = TestPolicy(keys: {a.id: a.identity.publicKey});
  final fb = () async {
    final sc = await respondHandshake(cb, b.identity, policy);
    return SyncEngine(b.store, batchSize: 2).run(sc, initiator: false);
  }();
  final fa = () async {
    final sc = await initiateHandshake(ca, a.identity,
        mode: HandshakeMode.sync, expectedId: b.id, expectedKey: b.identity.publicKey);
    return SyncEngine(a.store, batchSize: 2).run(sc, initiator: true);
  }();
  // Wait for both sides; report the first error after both finished.
  final results = await Future.wait([
    fa.then<Object>((v) => v, onError: (Object e) => e),
    fb.then<Object>((v) => v, onError: (Object e) => e),
  ]);
  for (final r in results) {
    if (r is! SyncStats) throw r;
  }
  return (results[0] as SyncStats, results[1] as SyncStats);
}
