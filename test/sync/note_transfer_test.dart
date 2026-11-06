import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/data/attachment_storage.dart';
import 'package:notevibe/data/note_store.dart';
import 'package:notevibe/data/vault/encrypted_attachment_storage.dart';
import 'package:notevibe/data/vault/vault_key.dart';
import 'package:notevibe/sync/transfer/note_transfer.dart';
import 'package:notevibe/sync/transfer/transfer_session.dart';

void main() {
  late Directory temp;
  late NoteStore sender;
  late NoteStore receiver;
  late AttachmentStorage source;
  late AttachmentStorage target;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('notehub-transfer-test-');
    sender = NoteStore.inMemory(deviceId: 'S');
    receiver = NoteStore.inMemory(deviceId: 'R');
    source = AttachmentStorage(Directory('${temp.path}/source'));
    target = AttachmentStorage(Directory('${temp.path}/target'));
  });
  tearDown(() async { sender.dispose(); receiver.dispose(); await temp.delete(recursive: true); });

  Future<RemoteNote> makeNote() async {
    final n = sender.createNote(title: 'Передать', content: '[{"insert":"Текст\\n"}]');
    final bytes = List.generate(NoteTransfer.chunkSize * 2 + 17, (i) => i % 251);
    final hash = await source.save(bytes);
    final a = sender.addAttachment(noteId: n.id, name: 'original.bin', mime: 'application/octet-stream', size: bytes.length, sha256: hash);
    sender.renameAttachment(a.id, 'Свой заголовок');
    return RemoteNote(sender.getNote(n.id)!, attachments: sender.attachmentsFor(n.id));
  }

  test('accepted TCP transfer imports metadata and verified multi-chunk bytes', () async {
    final item = await makeNote();
    final offer = await TransferSession.create(addresses: ['127.0.0.1']);
    addTearDown(offer.close);
    final client = await TransferSession.connect(offer.qr.encode());
    final server = await offer.connected;
    addTearDown(client.close); addTearDown(server.close);
    final sentProgress = <NoteTransferProgress>[];
    final receivedProgress = <NoteTransferProgress>[];
    final receiving = NoteTransfer.receive(server, receiver, target, confirm: (notes, bytes) async {
      expect(receiver.listNotes(), isEmpty);
      expect(notes.single.note.title, 'Передать');
      expect(bytes, item.attachments.single.size);
      return true;
    }, onProgress: receivedProgress.add);
    expect(await NoteTransfer.send(client, [item], source, onProgress: sentProgress.add), isTrue);
    final received = (await receiving).single;
    for (final updates in [sentProgress, receivedProgress]) {
      expect(updates.first.completedBytes, 0);
      expect(updates.last.completedBytes, item.attachments.single.size);
      expect(updates.last.totalBytes, item.attachments.single.size);
      expect(updates.last.finalizing, isTrue);
      expect(updates.map((p) => p.completedBytes), orderedEquals([0, NoteTransfer.chunkSize, NoteTransfer.chunkSize * 2,
        item.attachments.single.size, item.attachments.single.size]));
    }
    final a = receiver.attachmentsFor(received.id).single;
    expect(a.label, 'Свой заголовок');
    expect(a.name, 'original.bin');
    expect(await target.fileFor(a.sha256).readAsBytes(), await source.fileFor(a.sha256).readAsBytes());
    expect(received.id, isNot(item.note.id));
    expect(receiver.listPeers(), isEmpty);
    expect(await target.root.list().where((f) => f.path.contains('.notehub-transfer-')).length, 0);
  });

  test('declining imports nothing and writes no incoming files', () async {
    final item = await makeNote();
    final offer = await TransferSession.create(addresses: ['127.0.0.1']);
    addTearDown(offer.close);
    final client = await TransferSession.connect(offer.qr.encode());
    final server = await offer.connected;
    addTearDown(client.close); addTearDown(server.close);
    final receiving = NoteTransfer.receive(server, receiver, target, confirm: (_, _) async => false);
    expect(await NoteTransfer.send(client, [item], source), isFalse);
    expect(await receiving, isEmpty);
    expect(receiver.listNotes(), isEmpty);
    expect(await target.root.exists(), isFalse);
  });

  test('transfer supports encrypted source, staging and destination', () async {
    final item = await makeNote();
    final a = item.attachments.single;
    final encryptedSource = EncryptedAttachmentStorage(Directory('${temp.path}/encrypted-source'), await VaultKey.create());
    final encryptedTarget = EncryptedAttachmentStorage(Directory('${temp.path}/encrypted-target'), await VaultKey.create());
    final expected = await source.readVerified(a.sha256, size: a.size);
    await encryptedSource.save(expected);
    final offer = await TransferSession.create(addresses: ['127.0.0.1']);
    addTearDown(offer.close);
    final client = await TransferSession.connect(offer.qr.encode());
    final server = await offer.connected;
    addTearDown(client.close); addTearDown(server.close);
    final receiving = NoteTransfer.receive(server, receiver, encryptedTarget, confirm: (_, _) async => true);
    expect(await NoteTransfer.send(client, [item], encryptedSource), isTrue);
    expect(await receiving, hasLength(1));
    expect(await encryptedTarget.readVerified(a.sha256, size: a.size), expected);
    final disk = await encryptedTarget.root.list(recursive: true).where((e) => e is File).toList();
    expect(disk, hasLength(1));
    expect(disk.single.path.endsWith('.nhv'), isTrue);
    expect(await File(disk.single.path).readAsBytes(), isNot(expected));
  });

  test('connection lost after acceptance leaves no notes or staging files', () async {
    final item = await makeNote();
    final offer = await TransferSession.create(addresses: ['127.0.0.1']);
    addTearDown(offer.close);
    final client = await TransferSession.connect(offer.qr.encode());
    final server = await offer.connected;
    addTearDown(client.close); addTearDown(server.close);
    final receiving = expectLater(NoteTransfer.receive(server, receiver, target,
      confirm: (_, _) async => true), throwsException);
    await client.send({'t': 'notehub-transfer', 'v': 1, 'notes': [
      {'note': item.note.toWire(), 'files': [for (final a in item.attachments) a.toWire()]},
    ]});
    expect((await client.receive())['t'], 'accepted');
    await client.close();
    await receiving;
    expect(receiver.listNotes(), isEmpty);
    expect(receiver.allAttachments(), isEmpty);
    expect(await target.root.list().length, 0);
  });
}
