import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/data/attachment_storage.dart';
import 'package:notevibe/data/note_store.dart';
import 'package:notevibe/domain/attachment.dart';

void main() {
  late NoteStore store;
  late Directory dir;
  late AttachmentStorage files;

  setUp(() {
    store = NoteStore.inMemory(deviceId: 'T');
    dir = Directory.systemTemp.createTempSync('nv_attach_test');
    files = AttachmentStorage(dir);
  });

  tearDown(() {
    store.dispose();
    dir.deleteSync(recursive: true);
  });

  test('attachment is stored by hash, deduplicated and exported intact', () async {
    final note = store.createNote(title: 'with file');
    final bytes = List<int>.generate(1000, (i) => i % 256);

    final hash = await files.save(bytes);
    expect(hash, AttachmentStorage.sha256Of(bytes));
    expect(await files.save(bytes), hash); // same bytes: stored once

    store.addAttachment(
      noteId: note.id,
      name: 'photo.jpg',
      mime: 'image/jpeg',
      size: bytes.length,
      sha256: hash,
    );
    final list = store.attachmentsFor(note.id);
    expect(list, hasLength(1));
    expect(list.single.name, 'photo.jpg');
    expect(list.single.sizeLabel, '1000 Б');

    final out = File('${dir.path}/out/photo.jpg');
    await files.exportTo(hash, out);
    expect(await out.readAsBytes(), bytes);
  });

  test('damaged file is refused on export', () async {
    final hash = await files.save([1, 2, 3]);
    await files.fileFor(hash).writeAsBytes([9, 9, 9]);
    await expectLater(
      files.exportTo(hash, File('${dir.path}/x.bin')),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('display name changes metadata without changing original name or hash', () {
    final note = store.createNote(title: 'names');
    final a = store.addAttachment(noteId: note.id, name: 'original.pdf', mime: 'application/pdf', size: 3, sha256: 'hash');
    final before = store.getNote(note.id)!.version.toString();
    store.renameAttachment(a.id, ' Чек за продукты ');
    final renamed = store.attachmentsFor(note.id).single;
    expect(renamed.label, 'Чек за продукты');
    expect(renamed.name, 'original.pdf');
    expect(renamed.sha256, a.sha256);
    expect(store.getNote(note.id)!.version.toString(), isNot(before));
    final wire = Attachment.fromWire(renamed.toWire(), noteId: note.id);
    expect(wire.label, renamed.label);
    store.renameAttachment(a.id, '');
    expect(store.attachmentsFor(note.id).single.label, 'original.pdf');
    expect(() => store.renameAttachment(a.id, 'bad\nname'), throwsArgumentError);
  });

  test('files over the limit are rejected', () async {
    expect(maxAttachmentBytes, 100 * 1024 * 1024);
    await expectLater(
      files.save(List<int>.filled(maxAttachmentBytes + 1, 0)),
      throwsA(isA<FormatException>()),
    );
  });

  test('attachment aliases sync and reset across two independent stores', () {
    final peer = NoteStore.inMemory(deviceId: 'P');
    addTearDown(peer.dispose);
    final note = store.createNote(title: 'Shared file');
    final attachment = store.addAttachment(noteId: note.id, name: 'original.pdf',
      mime: 'application/pdf', size: 3, sha256: 'unchanged-hash');
    void send(NoteStore from, NoteStore to, String sender, int cursor) {
      final attachments = from.attachmentsFor(note.id).map((a) =>
        Attachment.fromWire(a.toWire(), noteId: note.id)).toList();
      to.applyRemoteBatch(sender, [RemoteNote(from.getNote(note.id)!, attachments: attachments)], newCursor: cursor);
    }
    store.renameAttachment(attachment.id, 'Мой документ');
    send(store, peer, 'T', 1);
    expect(peer.attachmentsFor(note.id).single.label, 'Мой документ');
    peer.updateNote(note.id, title: 'Edited on peer');
    send(peer, store, 'P', 1);
    expect(store.attachmentsFor(note.id).single.label, 'Мой документ');
    peer.renameAttachment(attachment.id, '');
    send(peer, store, 'P', 2);
    final reset = store.attachmentsFor(note.id).single;
    expect(reset.displayName, isNull);
    expect(reset.name, 'original.pdf');
    expect(reset.sha256, attachment.sha256);
    expect(store.conflictCount, 0);
  });

  test('deleting a note removes its attachment rows', () {
    final note = store.createNote(title: 'to delete');
    store.addAttachment(
      noteId: note.id,
      name: 'a.txt',
      mime: 'text/plain',
      size: 3,
      sha256: 'abc',
    );
    store.deleteNote(note.id);
    expect(store.attachmentsFor(note.id), isEmpty);
  });
}
