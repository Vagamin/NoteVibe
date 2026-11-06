import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/data/attachment_storage.dart';
import 'package:notevibe/data/note_store.dart';
import 'package:notevibe/data/vault/vault_attachments.dart';
import 'package:notevibe/data/vault/vault_key.dart';
import 'package:notevibe/data/vault/vault_migration.dart';
import 'package:notevibe/data/vault/vault_snapshots.dart';
import 'package:notevibe/data/vault/vault_key_store.dart';
import 'package:notevibe/sync/crypto/keys.dart';

void main() {
  test('migration preserves originals and verifies encrypted database and attachment', () async {
    final dir = await Directory.systemTemp.createTemp('notehub-migration-test-');
    addTearDown(() => dir.delete(recursive: true));
    final dbFile = File('${dir.path}/legacy.db');
    final legacy = NoteStore.open(dbFile.path, deviceId: 'PC');
    addTearDown(legacy.dispose);
    final bytes = [1, 2, 3, 4];
    final storage = AttachmentStorage(dir);
    final hash = await storage.save(bytes);
    final note = legacy.createNote(title: 'Сохранить');
    final a = legacy.addAttachment(noteId: note.id, name: 'file.bin', mime: 'application/octet-stream', size: bytes.length, sha256: hash);
    legacy.renameAttachment(a.id, 'Моё имя');
    // Keep SQLite open: backup must include the committed WAL transactions.
    final target = Directory('${dir.path}/vault');
    final sourceKeys = MemoryKeyStore();
    final identity = await DeviceIdentity.loadOrCreate(sourceKeys, 'PC', 'Computer');
    await VaultMigration.prepare(legacyDatabase: dbFile, legacyFiles: dir, destination: target,
      deviceId: 'PC', password: 'Migration password', sourceKeys: sourceKeys);
    expect(legacy.getNote(note.id)!.title, 'Сохранить');
    expect(await dbFile.exists(), isTrue);
    expect(await storage.fileFor(hash).readAsBytes(), bytes);
    final key = await VaultKey.unwrap(await File('${target.path}/key.json').readAsString(), 'Migration password');
    final migratedIdentity = await DeviceIdentity.loadOrCreate(VaultKeyStore(Directory('${target.path}/keys'), key), 'PC', 'Computer');
    expect(migratedIdentity.publicKey, identity.publicKey);
    final database = await VaultSnapshots(Directory('${target.path}/snapshots'), key).restoreLatest();
    final imported = NoteStore.fromVaultDatabase(database.database, deviceId: 'PC');
    expect(imported.getNote(note.id)!.title, 'Сохранить');
    expect(imported.attachmentsFor(note.id).single.label, 'Моё имя');
    imported.dispose(); database.dispose();
    expect(await VaultAttachments(Directory('${target.path}/attachments'), key).readVerified(hash, size: 4), bytes);
    final decrypted = Directory('${dir.path}/decrypted');
    final restoredKeys = MemoryKeyStore();
    await expectLater(VaultMigration.preparePlaintext(source: target, destination: decrypted,
      deviceId: 'PC', password: 'wrong'), throwsException);
    expect(await decrypted.exists(), isFalse);
    await VaultMigration.preparePlaintext(source: target, destination: decrypted,
      deviceId: 'PC', password: 'Migration password', destinationKeys: (_) => restoredKeys);
    final restoredIdentity = await DeviceIdentity.loadOrCreate(restoredKeys, 'PC', 'Computer');
    expect(restoredIdentity.publicKey, identity.publicKey);
    final back = NoteStore.open('${decrypted.path}/notevibe.db', deviceId: 'PC');
    try {
      expect(back.getNote(note.id)!.title, 'Сохранить');
      expect(back.attachmentsFor(note.id).single.label, 'Моё имя');
    } finally { back.dispose(); }
    expect(await AttachmentStorage(decrypted).readVerified(hash, size: 4), bytes);
    expect(await target.exists(), isTrue);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('damaged original aborts preparation without changing legacy data', () async {
    final dir = await Directory.systemTemp.createTemp('notehub-migration-test-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/legacy.db');
    final store = NoteStore.open(file.path, deviceId: 'PC');
    final storage = AttachmentStorage(dir);
    final hash = await storage.save([1, 2, 3]);
    final note = store.createNote(title: 'Keep');
    store.addAttachment(noteId: note.id, name: 'a.bin', mime: '', size: 3, sha256: hash);
    store.dispose();
    await storage.fileFor(hash).writeAsBytes([9, 9, 9]);
    final before = await file.readAsBytes();
    final target = Directory('${dir.path}/vault');
    await expectLater(VaultMigration.prepare(legacyDatabase: file, legacyFiles: dir,
      destination: target, deviceId: 'PC', password: 'Test password'), throwsFormatException);
    expect(await target.exists(), isFalse);
    expect(await file.readAsBytes(), before);
    expect(await dir.list().where((e) => e.path.contains('.notehub-migration-')).length, 0);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
