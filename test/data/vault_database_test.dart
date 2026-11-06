import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/data/vault/vault_database.dart';
import 'package:notevibe/data/vault/vault_key.dart';

void main() {
  test('SQLite snapshot restores in RAM without plaintext database files', () async {
    final dir = await Directory.systemTemp.createTemp('notehub-vault-db-test-');
    addTearDown(() => dir.delete(recursive: true));
    final key = await VaultKey.create();
    final db = VaultDatabase.create();
    addTearDown(db.dispose);
    db.database.execute('CREATE TABLE private_notes (text TEXT);');
    db.database.execute('INSERT INTO private_notes VALUES (?)', ['Секретная заметка']);
    final snapshot = File('${dir.path}/snapshot.nhv');
    await db.snapshot(snapshot, key);
    final onDisk = await dir.list().toList();
    expect(onDisk, hasLength(1));
    expect(await FileSystemEntity.identical(onDisk.single.path, snapshot.path), isTrue);
    final restored = await VaultDatabase.restore(snapshot, key);
    addTearDown(restored.dispose);
    expect(restored.database.select('SELECT text FROM private_notes').single['text'], 'Секретная заметка');
    restored.database.execute('INSERT INTO private_notes VALUES (?)', ['Ещё одна']);
    expect(db.database.select('SELECT * FROM private_notes'), hasLength(1));
    await expectLater(VaultDatabase.restore(snapshot, await VaultKey.create()), throwsException);
    await expectLater(VaultDatabase.restore(snapshot, key, maxBytes: 100), throwsFormatException);
  });

  test('snapshots refuse uncommitted transactions and remain immutable', () async {
    final dir = await Directory.systemTemp.createTemp('notehub-vault-db-test-');
    addTearDown(() => dir.delete(recursive: true));
    final key = await VaultKey.create();
    final db = VaultDatabase.create();
    addTearDown(db.dispose);
    db.database.execute('CREATE TABLE items (id INTEGER); BEGIN; INSERT INTO items VALUES (1);');
    final file = File('${dir.path}/snapshot.nhv');
    await expectLater(db.snapshot(file, key), throwsStateError);
    expect(await file.exists(), isFalse);
    db.database.execute('COMMIT');
    final saving = db.snapshot(file, key);
    db.database.execute('INSERT INTO items VALUES (2)');
    await saving;
    final restored = await VaultDatabase.restore(file, key);
    addTearDown(restored.dispose);
    expect(restored.database.select('SELECT * FROM items'), hasLength(1));
    expect(db.database.select('SELECT * FROM items'), hasLength(2));
  });
}
