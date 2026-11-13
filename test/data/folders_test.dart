import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/data/note_store.dart';
import 'package:notevibe/domain/note.dart';

void main() {
  test('20 folder limit allows renaming and replacement after deletion', () {
    final store = NoteStore.inMemory(deviceId: 'A');
    addTearDown(store.dispose);
    for (var i = 0; i < NoteStore.maxFolders; i++) {
      store.createFolder('Папка $i');
    }
    expect(() => store.createFolder('Лишняя'), throwsStateError);
    expect(() => store.createNote(kind: 'folder'), throwsStateError);
    final folder = store.listFolders().first;
    store.updateNote(folder.id, title: 'Новое имя');
    store.createNote(title: 'Обычная заметка');
    store.deleteFolder(folder.id);
    store.createFolder('Замена');
    expect(store.listFolders(), hasLength(20));
    expect(store.listNotes().single.title, 'Обычная заметка');
  });
  test('folders sync, preserve contents and deleting folder keeps notes', () {
    final a = NoteStore.inMemory(deviceId: 'A');
    final b = NoteStore.inMemory(deviceId: 'B');
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    final folder = a.createFolder('Учёба');
    final note = a.createNote(title: 'Лекция', plainText: 'Важный текст');
    a.moveToFolder([note.id], folder.id);
    expect(a.listNotes().map((n) => n.id), [note.id]);
    expect(a.getNote(note.id)!.plainText, 'Важный текст');
    expect(Note.fromWire(a.getNote(note.id)!.toWire()).folderId, folder.id);
    b.applyRemoteBatch('A', [RemoteNote(a.getNote(folder.id)!), RemoteNote(a.getNote(note.id)!)], newCursor: 2);
    expect(b.listFolders().single.title, 'Учёба');
    expect(b.listNotes().single.folderId, folder.id);
    a.updateNote(folder.id, title: 'Обучение');
    b.applyRemoteBatch('A', [RemoteNote(a.getNote(folder.id)!)], newCursor: 3);
    expect(b.listFolders().single.title, 'Обучение');
    a.deleteFolder(folder.id);
    b.applyRemoteBatch('A', [RemoteNote(a.getNote(folder.id)!)], newCursor: 4);
    expect(b.listFolders(), isEmpty);
    expect(b.listNotes().single.plainText, 'Важный текст');
    expect(b.listNotes().single.deleted, isFalse);
  });
}
