import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/data/note_store.dart';
import 'package:notevibe/data/schema.dart';
import 'package:sqlite3/sqlite3.dart';

/// Migrations in the order real databases recorded them. 1.1.0 had the first four
/// plus saved_copies as the fifth (index 4). 1.2.0 inserted archived before it, so
/// archived is at index 4 and saved_copies at index 5 in the current list.
/// This order is frozen: the list below must not change.
const _shipped = [
  'CREATE TABLE notes',
  'CREATE TABLE attachments',
  'CREATE TABLE file_holders',
  'ALTER TABLE notes ADD COLUMN important',
  'ADD COLUMN archived',
  'CREATE TABLE IF NOT EXISTS saved_copies',
];

void main() {
  test('shipped migrations are never reordered or removed', () {
    final list = migrationsForTest();
    expect(list.length, greaterThanOrEqualTo(_shipped.length));
    for (var i = 0; i < _shipped.length; i++) {
      expect(list[i], contains(_shipped[i]), reason: 'migration $i changed or moved');
    }
  });

  test('archived sits after the 1.1.0 migrations and saved_copies follows it (frozen order)', () {
    final list = migrationsForTest();
    expect(list[4], contains('ADD COLUMN archived'));
    expect(list[5], contains('CREATE TABLE IF NOT EXISTS saved_copies'));
  });

  test('fresh database migrates to the latest version', () {

    final db = sqlite3.openInMemory();
    migrate(db);
    expect(db.select('PRAGMA user_version').first.values.first, schemaVersion);
    db.close();
  });

  test('database with saved_copies already created still migrates', () {
    final db = sqlite3.openInMemory();
    migrate(db);
    db.execute('PRAGMA user_version = 4');
    expect(() => migrate(db), returnsNormally);
    expect(db.select('PRAGMA user_version').first.values.first, schemaVersion);
    db.close();
  });

  test('store opens on an existing database', () {
    final store = NoteStore.inMemory(deviceId: 'PC');
    store.createNote(title: 'x');
    expect(store.listNotes().single.title, 'x');
    store.dispose();
  });
}
