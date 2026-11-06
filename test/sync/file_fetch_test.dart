import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/data/attachment_storage.dart';
import 'package:notevibe/data/vault/encrypted_attachment_storage.dart';
import 'package:notevibe/data/vault/vault_key.dart';
import 'package:notevibe/data/note_store.dart';
import 'package:notevibe/sync/crypto/keys.dart';
import 'package:notevibe/sync/crypto/secure_channel.dart';
import 'package:notevibe/sync/sync_service.dart';

Future<(SyncService, AttachmentStorage)> makeService(String id, Directory dir, {bool encrypted = false}) async {
  final store = NoteStore.inMemory(deviceId: id);
  final ks = MemoryKeyStore();
  final ident = await DeviceIdentity.loadOrCreate(ks, id, 'Device $id');
  final files = encrypted ? EncryptedAttachmentStorage(dir, await VaultKey.create()) : AttachmentStorage(dir);
  final s = SyncService(
    store: store,
    peerKeys: PeerKeys(ks),
    identity: ident,
    deviceKind: id == 'PHONE' ? 'phone' : 'pc',
    enableDiscovery: false,
    kdf: CodeKdf.fast,
    debounce: const Duration(milliseconds: 50),
    files: files,
  );
  await s.start(port: 0);
  return (s, files);
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
  late AttachmentStorage pcFiles, phoneFiles;
  late Directory tmp;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('nv_fetch');
    (pc, pcFiles) = await makeService('PC', Directory('${tmp.path}/pc'));
    (phone, phoneFiles) = await makeService('PHONE', Directory('${tmp.path}/phone'));
  });

  tearDown(() async {
    await pc.dispose();
    await phone.dispose();
    pc.store.dispose();
    phone.store.dispose();
    tmp.deleteSync(recursive: true);
  });

  test('metadata syncs, file is downloaded on request and verified', () async {
    final bytes = List<int>.generate(700 * 1024, (i) => (i * 7) % 256);
    final note = pc.store.createNote(title: 'with file');
    final hash = await pcFiles.save(bytes);
    pc.store.addAttachment(
      noteId: note.id,
      name: 'data.bin',
      mime: 'application/octet-stream',
      size: bytes.length,
      sha256: hash,
    );

    final (offer, _) = await pc.createPairingOffer();
    await phone.pairWithCode('127.0.0.1', pc.port, offer.code);
    await waitFor(() => phone.store.attachmentsFor(note.id).isNotEmpty);

    final a = phone.store.attachmentsFor(note.id).single;
    expect(phoneFiles.has(hash), isFalse);

    final received = <int>[];
    final sub = phone.transferEvents.listen((_) {
      received.add(phone.transfers[hash]!.received);
    });
    final download = phone.fetchAttachment(a);
    expect(identical(download, phone.fetchAttachment(a)), isTrue);
    await download;
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(received.any((n) => n > 0 && n < bytes.length), isTrue);
    expect(phone.transfers[hash]!.status, 'Загружено');
    expect(phone.transfers[hash]!.received, bytes.length);
    phone.clearFinishedTransfers();
    expect(phone.transfers, isEmpty);
    expect(phoneFiles.has(hash), isTrue);
    expect(await phoneFiles.fileFor(hash).readAsBytes(), bytes);
  });

  test('paired fetch works between two encrypted stores without plaintext paths', () async {
    final (a, aFiles) = await makeService('PC', Directory('${tmp.path}/encrypted-pc'), encrypted: true);
    final (b, bFiles) = await makeService('PHONE', Directory('${tmp.path}/encrypted-phone'), encrypted: true);
    try {
      final bytes = List.generate(300000, (i) => i % 251);
      final hash = await aFiles.save(bytes);
      final note = a.store.createNote(title: 'Encrypted source');
      a.store.addAttachment(noteId: note.id, name: 'data.bin', mime: '', size: bytes.length, sha256: hash);
      final (offer, _) = await a.createPairingOffer();
      await b.pairWithCode('127.0.0.1', a.port, offer.code);
      await waitFor(() => b.store.attachmentsFor(note.id).isNotEmpty);
      await b.fetchAttachment(b.store.attachmentsFor(note.id).single);
      expect(await bFiles.readVerified(hash, size: bytes.length), bytes);
      expect(() => aFiles.fileFor(hash), throwsUnsupportedError);
      expect(() => bFiles.fileFor(hash), throwsUnsupportedError);
      final entries = await bFiles.root.list(recursive: true).where((e) => e is File).toList();
      expect(entries.every((f) => f.path.endsWith('.nhv')), isTrue);
    } finally {
      await a.dispose(); await b.dispose();
      a.store.dispose(); b.store.dispose();
    }
  });

  test('download fails cleanly when the owner no longer has the file', () async {
    final note = pc.store.createNote(title: 'gone');
    final hash = await pcFiles.save([1, 2, 3, 4]);
    pc.store.addAttachment(
      noteId: note.id,
      name: 'gone.bin',
      mime: '',
      size: 4,
      sha256: hash,
    );
    final (offer, _) = await pc.createPairingOffer();
    await phone.pairWithCode('127.0.0.1', pc.port, offer.code);
    await waitFor(() => phone.store.attachmentsFor(note.id).isNotEmpty);

    await pcFiles.delete(hash);
    final a = phone.store.attachmentsFor(note.id).single;
    await expectLater(phone.fetchAttachment(a), throwsA(isA<PairingException>()));
    expect(phone.transfers[hash]!.status, 'Ошибка загрузки');
    expect(phoneFiles.has(hash), isFalse);
  });

  test('holders are reported: red when only a peer has the file, grey when nobody does', () async {
    final note = pc.store.createNote(title: 'holders');
    final hash = await pcFiles.save([5, 6, 7]);
    pc.store.addAttachment(noteId: note.id, name: 'h.bin', mime: '', size: 3, sha256: hash);
    final (offer, _) = await pc.createPairingOffer();
    await phone.pairWithCode('127.0.0.1', pc.port, offer.code);
    await waitFor(() => phone.store.attachmentsFor(note.id).isNotEmpty);

    await waitFor(() => phone.store.hasRemoteHolder(hash));
    expect(phoneFiles.has(hash), isFalse);

    await pcFiles.delete(hash);
    await phone.syncNow(force: true);
    await waitFor(() => !phone.store.hasRemoteHolder(hash));
  });
}
