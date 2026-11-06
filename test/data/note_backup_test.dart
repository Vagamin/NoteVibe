import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/data/attachment_storage.dart';
import 'package:notevibe/data/backup_zip.dart';
import 'package:notevibe/data/note_backup.dart';
import 'package:notevibe/data/note_store.dart';

void main() {
  test('ZIP restores notes and files; add preserves existing and replace removes them', () async {
    final dir = await Directory.systemTemp.createTemp('nv-backup-');
    addTearDown(() => dir.delete(recursive: true));
    final source = NoteStore.inMemory(deviceId: 'source');
    final target = NoteStore.inMemory(deviceId: 'target');
    addTearDown(source.dispose); addTearDown(target.dispose);
    final files = AttachmentStorage(Directory('${dir.path}/source'));
    final destination = AttachmentStorage(Directory('${dir.path}/target'));
    final note = source.createNote(title: 'Резервная заметка');
    final content = Uint8List.fromList([1, 2, 3]);
    final hash = await files.save(content);
    source.addAttachment(noteId: note.id, name: 'file.bin', mime: 'application/octet-stream', size: 3, sha256: hash);
    source.setArchived([note.id], true);
    final zip = await NoteBackup.export(source, files);
    expect(BackupZip.decode(zip).keys, contains('attachments/$hash'));
    final existing = target.createNote(title: 'Существующая');
    target.setSetting('device_name', 'Не менять');
    expect(await NoteBackup.restore(zip, target, destination, replace: false), 1);
    expect(target.getNote(existing.id)!.deleted, false);
    expect(await destination.readVerified(hash), content);
    expect(target.listArchived().length, 1);
    await NoteBackup.restore(zip, target, destination, replace: true);
    expect(target.getNote(existing.id)!.deleted, true);
    expect(target.backupNotes().length, 1);
    expect(target.getSetting('device_name'), 'Не менять');
    final db = BackupZip.decode(zip)['notevibe.db']!;
    await NoteBackup.restore(db, target, destination, replace: false);
    expect(target.backupNotes().length, 2);
  });

  test('corruption and unsafe paths fail without replacing notes', () async {
    final dir = await Directory.systemTemp.createTemp('nv-bad-backup-');
    addTearDown(() => dir.delete(recursive: true));
    final store = NoteStore.inMemory(deviceId: 'target');
    addTearDown(store.dispose);
    store.createNote(title: 'Сохранить');
    final bad = BackupZip.encode({'../notevibe.db': Uint8List(100)});
    await expectLater(NoteBackup.restore(bad, store, AttachmentStorage(dir), replace: true), throwsFormatException);
    expect(store.backupNotes().single.note.title, 'Сохранить');
  });
}
