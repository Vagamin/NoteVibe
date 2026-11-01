import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/data/attachment_storage.dart';
import 'package:notevibe/data/note_store.dart';

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

  test('files over the limit are rejected', () async {
    await expectLater(
      files.save(List<int>.filled(maxAttachmentBytes + 1, 0)),
      throwsA(isA<FormatException>()),
    );
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
