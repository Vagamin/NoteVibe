import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/sync/crypto/keys.dart';
import 'package:notevibe/sync/crypto/secure_channel.dart';
import 'package:notevibe/sync/transport/frame_channel.dart';

import 'helpers.dart';

void main() {
  late DeviceIdentity a, b, mallory;
  setUpAll(() async {
    a = await DeviceIdentity.fromSeed('A', 'PC', List.filled(32, 1));
    b = await DeviceIdentity.fromSeed('B', 'Phone', List.filled(32, 2));
    mallory = await DeviceIdentity.fromSeed('M', 'Evil', List.filled(32, 3));
  });

  Future<(SecureChannel, SecureChannel)> connect(
    DeviceIdentity init,
    DeviceIdentity resp,
    TestPolicy policy, {
    HandshakeMode mode = HandshakeMode.sync,
    List<int>? expectedKey,
    List<int>? secret,
  }) async {
    final (c1, c2) = MemoryFrameChannel.pair();
    final r = respondHandshake(c2, resp, policy, kdf: CodeKdf.fast);
    final i = initiateHandshake(c1, init,
        mode: mode, expectedKey: expectedKey, secret: secret, kdf: CodeKdf.fast);
    final results = await Future.wait([
      i.then<Object>((v) => v, onError: (Object e) => e),
      r.then<Object>((v) => v, onError: (Object e) => e),
    ]);
    for (final x in results) {
      if (x is! SecureChannel) throw x;
    }
    return (results[0] as SecureChannel, results[1] as SecureChannel);
  }

  test('identity is persisted in key store', () async {
    final ks = MemoryKeyStore();
    final i1 = await DeviceIdentity.loadOrCreate(ks, 'X', 'x');
    final i2 = await DeviceIdentity.loadOrCreate(ks, 'X', 'x');
    expect(i1.publicKey, i2.publicKey);
    expect(i1.fingerprint, hasLength(16));
  });

  test('sync handshake between paired devices and encrypted messages', () async {
    final (ia, rb) = await connect(a, b, TestPolicy(keys: {'A': a.publicKey}),
        expectedKey: b.publicKey);
    expect(ia.remote.deviceId, 'B');
    expect(rb.remote.deviceId, 'A');
    await ia.send({'hello': 'мир'});
    expect((await rb.receive())['hello'], 'мир');
    await rb.send({'x': 1});
    expect((await ia.receive())['x'], 1);
  });

  test('unknown device is rejected', () async {
    expect(
      connect(mallory, b, TestPolicy(keys: {'A': a.publicKey}), expectedKey: b.publicKey),
      throwsA(isA<HandshakeException>()),
    );
  });

  test('impersonation with wrong static key is rejected', () async {
    // Mallory claims to be A but has a different key.
    final fake = await DeviceIdentity.fromSeed('A', 'PC', List.filled(32, 3));
    await expectLater(
      connect(fake, b, TestPolicy(keys: {'A': a.publicKey}), expectedKey: b.publicKey),
      throwsA(isA<HandshakeException>()),
    );
  });

  test('initiator rejects responder with unexpected key', () async {
    await expectLater(
      connect(a, mallory, TestPolicy(keys: {'A': a.publicKey}), expectedKey: b.publicKey),
      throwsA(isA<HandshakeException>()),
    );
  });

  test('QR pairing succeeds with correct token, fails with wrong one', () async {
    final token = List<int>.generate(16, (i) => i);
    final p = TestPolicy()..qrToken = token;
    final (ia, _) = await connect(a, b, p,
        mode: HandshakeMode.pairQr, expectedKey: b.publicKey, secret: token);
    expect(ia.remote.staticKey, b.publicKey);

    await expectLater(
      connect(a, b, p,
          mode: HandshakeMode.pairQr, expectedKey: b.publicKey, secret: List.filled(16, 9)),
      throwsA(isA<HandshakeException>()),
    );
  });

  test('code pairing succeeds with right code and reports wrong code', () async {
    final p = TestPolicy()..code = '123456';
    final (ia, rb) = await connect(a, b, p,
        mode: HandshakeMode.pairCode, secret: utf8.encode('123456'));
    expect(ia.remote.staticKey, b.publicKey);
    expect(rb.remote.staticKey, a.publicKey);

    await expectLater(
      connect(a, b, p, mode: HandshakeMode.pairCode, secret: utf8.encode('654321')),
      throwsA(isA<HandshakeException>().having((e) => e.code, 'code', HsError.badCode)),
    );
    expect(p.failures, 1);
  });

  test('pairing is refused when no offer is active', () async {
    await expectLater(
      connect(a, b, TestPolicy(), mode: HandshakeMode.pairCode, secret: utf8.encode('000000')),
      throwsA(isA<HandshakeException>().having((e) => e.code, 'code', HsError.noPairing)),
    );
  });

  test('tampered ciphertext is detected', () async {
    final (c1, c2) = MemoryFrameChannel.pair();
    // Interpose: flip a bit in the 4th frame from A (first encrypted app msg).
    final (t1, t2) = MemoryFrameChannel.pair();
    var n = 0;
    () async {
      try {
        while (true) {
          final f = await c2.receive(timeout: const Duration(seconds: 5));
          n++;
          if (n == 3) f[0] ^= 1;
          await t1.send(Uint8List.fromList(f));
        }
      } catch (_) {}
    }();
    () async {
      try {
        while (true) {
          await c2.send(await t1.receive(timeout: const Duration(seconds: 5)));
        }
      } catch (_) {}
    }();
    final r = respondHandshake(t2, b, TestPolicy(keys: {'A': a.publicKey}));
    final ia = await initiateHandshake(c1, a, mode: HandshakeMode.sync, expectedKey: b.publicKey);
    final rb = await r;
    await ia.send({'secret': 'data'});
    await expectLater(rb.receive(), throwsA(isA<TransportException>()));
  });
}
