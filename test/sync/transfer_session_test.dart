import 'dart:typed_data';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/sync/transfer/transfer_session.dart';
import 'package:notevibe/sync/discovery/lan_discovery.dart';

void main() {
  DiscoveredDevice sender(TransferSession session) => DiscoveredDevice(
    deviceId: session.qr.id, name: 'Test sender', address: '127.0.0.1',
    port: session.qr.port, fingerprint: base64UrlEncode(session.qr.key), seenAt: DateTime.now());

  test('six digit code authenticates encrypted single-use transfer', () async {
    final session = await TransferSession.create(addresses: ['127.0.0.1']);
    addTearDown(session.close);
    expect(session.code, matches(RegExp(r'^\d{6}$')));
    final client = await TransferSession.connectCode(sender(session), session.code);
    final server = await session.connected;
    addTearDown(client.close);
    addTearDown(server.close);
    await client.send({'t': 'test', 'text': 'Private'});
    expect((await server.receive())['text'], 'Private');
    await expectLater(TransferSession.connectCode(sender(session), session.code), throwsException);
  });

  test('three wrong short codes revoke QR and code together', () async {
    final session = await TransferSession.create(addresses: ['127.0.0.1']);
    addTearDown(session.close);
    final wrong = session.code == '000000' ? '111111' : '000000';
    final revoked = expectLater(session.connected, throwsException);
    for (var i = 0; i < 3; i++) {
      await expectLater(TransferSession.connectCode(sender(session), wrong), throwsException);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await revoked;
    await expectLater(TransferSession.connect(session.qr.encode()), throwsException);
  });

  test('transfer QR is separate from pairing and rejects unsafe targets', () async {
    final session = await TransferSession.create(addresses: ['127.0.0.1']);
    addTearDown(session.close);
    final encoded = session.qr.encode();
    expect(TransferQr.tryParse(encoded)!.id, session.qr.id);
    expect(TransferQr.tryParse(encoded.replaceFirst('notehub://transfer', 'notevibe://pair')), isNull);
    expect(TransferQr.tryParse(encoded.replaceFirst('127.0.0.1', '8.8.8.8')), isNull);
    expect(TransferQr.tryParse(encoded.replaceFirst('127.0.0.1', 'example.com')), isNull);
    final uri = Uri.parse(encoded);
    expect(TransferQr.tryParse(uri.replace(queryParameters: {...uri.queryParameters,
      'e': '${DateTime.now().subtract(const Duration(seconds: 1)).millisecondsSinceEpoch}'}).toString()), isNull);
  });

  test('single-use offer exchanges authenticated encrypted messages over TCP', () async {
    final session = await TransferSession.create(addresses: ['127.0.0.1']);
    addTearDown(session.close);
    final client = await TransferSession.connect(session.qr.encode());
    final server = await session.connected;
    addTearDown(client.close);
    addTearDown(server.close);
    await client.send({'t': 'transfer', 'title': 'Личная заметка'});
    expect((await server.receive())['title'], 'Личная заметка');
    await server.send({'t': 'accepted'});
    expect((await client.receive())['t'], 'accepted');
    await expectLater(TransferSession.connect(session.qr.encode()), throwsException);
  });

  test('wrong pinned key fails and does not consume the valid QR', () async {
    final session = await TransferSession.create(addresses: ['127.0.0.1']);
    addTearDown(session.close);
    final qr = session.qr;
    final bad = TransferQr(id: qr.id, key: Uint8List(32), token: qr.token,
      addresses: qr.addresses, port: qr.port, expiresAt: qr.expiresAt);
    await expectLater(TransferSession.connect(bad.encode()), throwsException);
    // Let the responder finish handling the failed handshake before retrying.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final client = await TransferSession.connect(qr.encode());
    final server = await session.connected;
    addTearDown(client.close);
    addTearDown(server.close);
    expect(server.remote.name, 'Разовая передача');
  });

  test('closing an offer fails pending connection future', () async {
    final session = await TransferSession.create(addresses: ['127.0.0.1']);
    final result = expectLater(session.connected, throwsException);
    await session.close();
    await result;
    await expectLater(TransferSession.connect(session.qr.encode()), throwsException);
  });

  test('offer expires without a connection and stops listening', () async {
    final session = await TransferSession.create(addresses: ['127.0.0.1'],
      lifetime: const Duration(milliseconds: 100));
    addTearDown(session.close);
    await expectLater(session.connected, throwsException);
    expect(TransferQr.tryParse(session.qr.encode()), isNull);
    await expectLater(TransferSession.connect(session.qr.encode()), throwsFormatException);
  });

  test('wrong secret cannot authenticate and three failures revoke offer', () async {
    final session = await TransferSession.create(addresses: ['127.0.0.1']);
    addTearDown(session.close);
    final qr = session.qr;
    final bad = TransferQr(id: qr.id, key: qr.key, token: Uint8List(32),
      addresses: qr.addresses, port: qr.port, expiresAt: qr.expiresAt);
    final revoked = expectLater(session.connected, throwsException);
    for (var i = 0; i < 3; i++) {
      await expectLater(TransferSession.connect(bad.encode()), throwsException);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await revoked;
    await expectLater(TransferSession.connect(qr.encode()), throwsException);
  });
}
