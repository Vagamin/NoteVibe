import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/data/attachment_storage.dart';
import 'package:notevibe/data/note_store.dart';
import 'package:notevibe/sync/crypto/keys.dart';
import 'package:notevibe/sync/crypto/secure_channel.dart';
import 'package:notevibe/sync/sync_service.dart';

Future<(SyncService, AttachmentStorage)> makeService(String id, Directory dir) async {
  final store = NoteStore.inMemory(deviceId: id);
  final ks = MemoryKeyStore();
  final ident = await DeviceIdentity.loadOrCreate(ks, id, 'Device $id');
  final files = AttachmentStorage(dir);
  final s = SyncService(
    store: store,
    peerKeys: PeerKeys(ks),
    identity: ident,
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

    await phone.fetchAttachment(a);
    expect(phoneFiles.has(hash), isTrue);
    expect(await phoneFiles.fileFor(hash).readAsBytes(), bytes);
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
