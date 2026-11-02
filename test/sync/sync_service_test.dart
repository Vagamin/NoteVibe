import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/data/note_store.dart';
import 'package:notevibe/sync/crypto/keys.dart';
import 'package:notevibe/sync/crypto/secure_channel.dart';
import 'package:notevibe/sync/pairing/pairing.dart';
import 'package:notevibe/sync/sync_service.dart';

Future<SyncService> makeService(String id) async {
  final store = NoteStore.inMemory(deviceId: id);
  final ks = MemoryKeyStore();
  final ident = await DeviceIdentity.loadOrCreate(ks, id, 'Device $id');
  final s = SyncService(
    store: store,
    peerKeys: PeerKeys(ks),
    identity: ident,
    enableDiscovery: false,
    kdf: CodeKdf.fast,
    debounce: const Duration(milliseconds: 50),
  );
  await s.start(port: 0);
  return s;
}

Future<void> waitFor(bool Function() cond, {Duration timeout = const Duration(seconds: 10)}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late SyncService pc, phone;

  setUp(() async {
    pc = await makeService('PC');
    phone = await makeService('PHONE');
  });

  tearDown(() async {
    await pc.dispose();
    await phone.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    pc.store.dispose();
    phone.store.dispose();
  });

  test('QR pairing over TCP then automatic sync both ways', () async {
    pc.store.createNote(title: 'PC note');
    final (_, qr) = await pc.createPairingOffer();
    final parsed = PairingQr.tryParse(qr.encode())!;
    // Force localhost for the test.
    final local = PairingQr(
      deviceId: parsed.deviceId,
      name: parsed.name,
      publicKey: parsed.publicKey,
      token: parsed.token,
      addresses: ['127.0.0.1'],
      port: parsed.port,
    );
    final name = await phone.pairWithQr(local);
    expect(name, 'Device PC');
    await waitFor(() => pc.store.getPeer('PHONE') != null);

    // Auto sync after pairing pulls the PC note to the phone.
    await waitFor(() => phone.store.listNotes().length == 1);

    // Edit on phone -> auto sync (debounced) -> appears on PC.
    final n = phone.store.listNotes().single;
    phone.store.updateNote(n.id, title: 'edited on phone');
    await waitFor(() => pc.store.getNote(n.id)?.title == 'edited on phone');
    await waitFor(() => phone.currentStatus.state == SyncState.synced);
  });

  test('offer is single-use and wrong code is rejected', () async {
    final (offer, qr) = await pc.createPairingOffer();
    final wrong = offer.code == '000000' ? '111111' : '000000';
    await expectLater(phone.pairWithCode('127.0.0.1', pc.port, wrong),
        throwsA(isA<PairingException>()));
    expect(offer.failedAttempts, 1);

    await phone.pairWithCode('127.0.0.1', pc.port, offer.code);
    await waitFor(() => pc.store.getPeer('PHONE') != null);
    expect(pc.offer, isNull); // used

    final third = await makeService('X');
    await expectLater(third.pairWithCode('127.0.0.1', pc.port, offer.code),
        throwsA(isA<PairingException>()));
    await third.dispose();
    third.store.dispose();
  });

  test('auto sync can be disabled; offline status when peer is down', () async {
    final (offer, _) = await pc.createPairingOffer();
    await phone.pairWithCode('127.0.0.1', pc.port, offer.code);
    await waitFor(() => phone.currentStatus.state == SyncState.synced);

    phone.autoSync = false;
    pc.autoSync = false;
    phone.store.createNote(title: 'not yet');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(pc.store.listNotes(), isEmpty);

    await phone.syncNow(force: true);
    expect(pc.store.listNotes().single.title, 'not yet');

    await pc.stop();
    phone.store.createNote(title: 'while offline');
    await phone.syncNow(force: true);
    expect(phone.currentStatus.state, SyncState.offline);
    expect(phone.currentStatus.lastError, isNotNull);
  });

  test('unpaired device is refused', () async {
    final (offer, _) = await pc.createPairingOffer();
    await phone.pairWithCode('127.0.0.1', pc.port, offer.code);
    await waitFor(() => pc.store.getPeer('PHONE') != null);
    await pc.unpair('PHONE');
    phone.store.createNote(title: 'secret');
    await phone.syncNow(force: true);
    expect(pc.store.listNotes(), isEmpty);
    expect(phone.currentStatus.lastError, contains('не сопряжено'));
  });
}
