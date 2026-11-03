import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/data/note_store.dart';

class FakeClock {
  DateTime t = DateTime(2026, 1, 1, 12);
  DateTime call() => t = t.add(const Duration(seconds: 1));
}

void main() {
  group('trash', () {
    test('trashed note leaves the list and can be restored', () {
      final s = NoteStore.inMemory(deviceId: 'A', now: FakeClock().call);
      final n = s.createNote(title: 'a');
      s.trashNotes([n.id]);
      expect(s.listNotes(), isEmpty);
      expect(s.listTrashed().single.id, n.id);
      s.restoreNotes([n.id]);
      expect(s.listTrashed(), isEmpty);
      expect(s.listNotes().single.id, n.id);
    });

    test('with trash turned off a removed note is deleted at once', () {
      final s = NoteStore.inMemory(deviceId: 'A', now: FakeClock().call);
      s.setSetting(NoteStore.trashDaysSetting, '0');
      final n = s.createNote(title: 'a');
      s.removeNotes([n.id]);
      expect(s.getNote(n.id)!.deleted, isTrue);
      expect(s.listTrashed(), isEmpty);
    });

    test('expired trashed notes are purged, fresh ones stay', () {
      final clock = FakeClock();
      final s = NoteStore.inMemory(deviceId: 'A', now: clock.call);
      s.setSetting(NoteStore.trashDaysSetting, '1');
      final old = s.createNote(title: 'old');
      s.trashNotes([old.id]);
      clock.t = clock.t.add(const Duration(days: 2));
      final fresh = s.createNote(title: 'fresh');
      s.trashNotes([fresh.id]);
      s.purgeExpiredTrash();
      expect(s.getNote(old.id)!.deleted, isTrue);
      expect(s.getNote(fresh.id)!.deleted, isFalse);
    });

    test('«never» keeps trashed notes', () {
      final clock = FakeClock();
      final s = NoteStore.inMemory(deviceId: 'A', now: clock.call);
      s.setSetting(NoteStore.trashDaysSetting, '-1');
      final n = s.createNote(title: 'keep');
      s.trashNotes([n.id]);
      clock.t = clock.t.add(const Duration(days: 400));
      s.purgeExpiredTrash();
      expect(s.getNote(n.id)!.deleted, isFalse);
    });

    test('trash state syncs to another device', () {
      final clock = FakeClock();
      final a = NoteStore.inMemory(deviceId: 'A', now: clock.call);
      final b = NoteStore.inMemory(deviceId: 'B', now: clock.call);
      final n = a.createNote(title: 'x');
      a.trashNotes([n.id]);
      final batch = a.changesSince(0);
      b.applyRemoteBatch('A', batch.notes, newCursor: batch.lastSeq);
      expect(b.listTrashed().single.id, n.id);
      expect(b.listNotes(), isEmpty);
    });
  });

  group('voice notes', () {
    test('voice kind is stored and syncs to another device', () {
      final clock = FakeClock();
      final a = NoteStore.inMemory(deviceId: 'A', now: clock.call);
      final b = NoteStore.inMemory(deviceId: 'B', now: clock.call);
      final n = a.createNote(title: 'Голос', kind: 'voice');
      expect(a.getNote(n.id)!.isVoice, isTrue);
      final batch = a.changesSince(0);
      b.applyRemoteBatch('A', batch.notes, newCursor: batch.lastSeq);
      expect(b.getNote(n.id)!.isVoice, isTrue);
    });

    test('recording is an attachment of the voice note', () {
      final s = NoteStore.inMemory(deviceId: 'A', now: FakeClock().call);
      final n = s.createNote(title: 'Голос', kind: 'voice');
      s.addAttachment(
        noteId: n.id,
        name: 'Голос 1.m4a',
        mime: 'audio/mp4',
        size: 10,
        sha256: 'abc',
      );
      final list = s.attachmentsFor(n.id);
      expect(list.single.mime, 'audio/mp4');
    });
  });

  group('manual order', () {
    test('setOrder assigns positions and listNotes(manual) follows them', () {
      final s = NoteStore.inMemory(deviceId: 'A', now: FakeClock().call);
      final a = s.createNote(title: 'a');
      final b = s.createNote(title: 'b');
      final c = s.createNote(title: 'c');
      s.setOrder([c.id, a.id, b.id]);
      expect(s.listNotes(manual: true).map((n) => n.id), [c.id, a.id, b.id]);
    });

    test('reordering keeps the date sort unchanged', () {
      final s = NoteStore.inMemory(deviceId: 'A', now: FakeClock().call);
      final a = s.createNote(title: 'a');
      final b = s.createNote(title: 'b');
      final before = s.listNotes().map((n) => n.id).toList();
      s.setOrder([a.id, b.id]);
      expect(s.listNotes().map((n) => n.id).toList(), before);
    });

    test('important notes stay on top in manual order', () {
      final s = NoteStore.inMemory(deviceId: 'A', now: FakeClock().call);
      final a = s.createNote(title: 'a');
      final b = s.createNote(title: 'b');
      s.setImportant(b.id, true);
      s.setOrder([a.id, b.id]);
      expect(s.listNotes(manual: true).map((n) => n.id), [b.id, a.id]);
    });
  });
}
