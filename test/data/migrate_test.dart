import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/data/note_store.dart';
import 'package:notevibe/data/schema.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
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
