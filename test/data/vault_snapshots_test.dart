import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/data/vault/vault_database.dart';
import 'package:notevibe/data/vault/vault_key.dart';
import 'package:notevibe/data/vault/vault_snapshots.dart';

void main() {
  late Directory dir;
  late VaultDatabase db;
  late VaultSnapshots snapshots;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('notehub-snapshots-test-');
    db = VaultDatabase.create();
    db.database.execute('CREATE TABLE notes (title TEXT); INSERT INTO notes VALUES (\'First\');');
    snapshots = VaultSnapshots(dir, await VaultKey.create());
  });
  tearDown(() async { db.dispose(); await dir.delete(recursive: true); });

  test('verified generations restore latest and allow explicit older recovery', () async {
    expect(await snapshots.save(db), 1);
    db.database.execute('INSERT INTO notes VALUES (\'Second\')');
    expect(await snapshots.save(db), 2);
    expect(await snapshots.generations(), [1, 2]);
    final latest = await snapshots.restoreLatest();
    addTearDown(latest.dispose);
    expect(latest.database.select('SELECT * FROM notes'), hasLength(2));
    final old = await snapshots.restoreGeneration(1);
    addTearDown(old.dispose);
    expect(old.database.select('SELECT * FROM notes'), hasLength(1));
  });

  test('partial staging is ignored and failed save preserves committed state', () async {
    await snapshots.save(db);
    final interrupted = await dir.createTemp('.pending-');
    await File('${interrupted.path}/database.nhv').writeAsBytes([1, 2, 3]);
    db.database.execute('BEGIN; INSERT INTO notes VALUES (\'Uncommitted\')');
    await expectLater(snapshots.save(db), throwsStateError);
    db.database.execute('ROLLBACK');
    expect(await snapshots.generations(), [1]);
    final restored = await snapshots.restoreLatest();
    addTearDown(restored.dispose);
    expect(restored.database.select('SELECT * FROM notes'), hasLength(1));
  });

  test('corrupt latest does not silently fall back to an older generation', () async {
    await snapshots.save(db);
    await snapshots.save(db);
    final latest = File('${dir.path}/snapshot-000000000002.nhv');
    final bytes = await latest.readAsBytes();
    bytes[30] ^= 1;
    await latest.writeAsBytes(bytes);
    await expectLater(snapshots.restoreLatest(), throwsException);
    final recovered = await snapshots.restoreGeneration(1);
    addTearDown(recovered.dispose);
    expect(recovered.database.select('SELECT * FROM notes'), hasLength(1));
  });

  test('concurrent saves are refused instead of racing snapshot publication', () async {
    final pending = snapshots.save(db);
    await expectLater(snapshots.save(db), throwsStateError);
    await pending;
    expect(await snapshots.generations(), [1]);
  });
}
