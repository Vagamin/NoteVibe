import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/data/vault/vault_database.dart';
import 'package:notevibe/data/vault/vault_key.dart';
import 'package:notevibe/data/vault/vault_note_store.dart';
import 'package:notevibe/data/vault/vault_snapshots.dart';

void main() {
  test('real note store survives encrypted save and reopen with metadata', () async {
    final dir = await Directory.systemTemp.createTemp('notehub-vault-store-test-');
    addTearDown(() => dir.delete(recursive: true));
    final key = await VaultKey.create();
    final snapshots = VaultSnapshots(dir, key);
    final vault = VaultNoteStore(VaultDatabase.create(), snapshots, deviceId: 'PC');
    final n = vault.store.createNote(title: 'Секретная заметка');
    final a = vault.store.addAttachment(noteId: n.id, name: 'original.pdf', mime: 'application/pdf', size: 3, sha256: 'a' * 64);
    vault.store.renameAttachment(a.id, 'Мой документ');
    vault.store.setSetting('device_name', 'Мой ПК');
    vault.store.updateNote(n.id, title: 'Последняя версия');
    await vault.flush();
    expect(vault.hasUnsavedChanges, isFalse);
    await vault.close();
    final reopened = VaultNoteStore(await snapshots.restoreLatest(), snapshots, deviceId: 'PC');
    expect(reopened.store.getNote(n.id)!.title, 'Последняя версия');
    expect(reopened.store.attachmentsFor(n.id).single.label, 'Мой документ');
    expect(reopened.store.getSetting('device_name'), 'Мой ПК');
    await reopened.close();
    final entries = await dir.list().toList();
    expect(entries.every((e) => e.path.endsWith('.nhv')), isTrue);
  });

  test('failed persistence stays dirty, close refuses data loss and retry works', () async {
    final dir = await Directory.systemTemp.createTemp('notehub-vault-store-test-');
    addTearDown(() => dir.delete(recursive: true));
    final blocked = File('${dir.path}/blocked');
    await blocked.writeAsString('not a directory');
    final snapshots = VaultSnapshots(Directory(blocked.path), await VaultKey.create());
    final vault = VaultNoteStore(VaultDatabase.create(), snapshots, deviceId: 'PC');
    vault.store.createNote(title: 'Не потерять');
    await expectLater(vault.flush(), throwsA(isA<FileSystemException>()));
    expect(vault.lastSaveError, isA<FileSystemException>());
    expect(vault.hasUnsavedChanges, isTrue);
    await expectLater(vault.close(), throwsA(isA<FileSystemException>()));
    expect(vault.store.listNotes().single.title, 'Не потерять');
    await blocked.delete();
    await vault.flush();
    expect(vault.hasUnsavedChanges, isFalse);
    expect(vault.lastSaveError, isNull);
    await vault.close();
    final restored = VaultNoteStore(await snapshots.restoreLatest(), snapshots, deviceId: 'PC');
    expect(restored.store.listNotes().single.title, 'Не потерять');
    await restored.close();
  });
}
