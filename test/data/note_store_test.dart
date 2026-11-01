import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/data/note_store.dart';
import 'package:notevibe/domain/conflict.dart';
import 'package:notevibe/domain/version_vector.dart';

class FakeClock {
  DateTime t = DateTime(2026, 1, 1, 12);
  DateTime call() => t = t.add(const Duration(seconds: 1));
}

void main() {
  group('VersionVector', () {
    test('compare', () {
      final a = VersionVector({'A': 1});
      final b = a.increment('B');
      expect(a.compare(b), VvOrder.before);
      expect(b.compare(a), VvOrder.after);
      expect(a.compare(VersionVector({'A': 1})), VvOrder.equal);
      expect(a.increment('A').compare(b), VvOrder.concurrent);
    });

    test('merge and encode roundtrip', () {
      final m = VersionVector({'A': 3, 'B': 1}).merge(VersionVector({'B': 5, 'C': 2}));
      expect(m.entries, {'A': 3, 'B': 5, 'C': 2});
      expect(VersionVector.decode(m.encode()), m);
    });
  });

  group('NoteStore', () {
    late NoteStore store;
    setUp(() => store = NoteStore.inMemory(deviceId: 'A', now: FakeClock().call));
    tearDown(() => store.dispose());

    test('create, read, update, list', () {
      final n = store.createNote(title: 'Покупки', plainText: 'молоко');
      expect(n.id, hasLength(36));
      expect(n.version['A'], 1);

      final u = store.updateNote(n.id, title: 'Покупки 2')!;
      expect(u.version['A'], 2);
      expect(u.updatedAt.isAfter(n.updatedAt), isTrue);
      expect(u.createdAt, n.createdAt);
      expect(store.getNote(n.id)!.title, 'Покупки 2');
      expect(store.listNotes(), hasLength(1));
    });

    test('update without changes does not bump version', () {
      final n = store.createNote(title: 'x');
      expect(store.updateNote(n.id, title: 'x'), isNull);
      expect(store.getNote(n.id)!.version['A'], 1);
    });

    test('unique ids', () {
      final ids = {for (var i = 0; i < 50; i++) store.createNote().id};
      expect(ids, hasLength(50));
    });

    test('search is case-insensitive and Unicode aware', () {
      store.createNote(title: 'Рецепт', plainText: 'Борщ со СМЕТАНОЙ');
      store.createNote(title: 'Work', plainText: 'meeting');
      expect(store.listNotes(query: 'сметан').single.title, 'Рецепт');
      expect(store.listNotes(query: 'РЕЦЕПТ'), hasLength(1));
      expect(store.listNotes(query: 'MEET').single.title, 'Work');
      expect(store.listNotes(query: 'nothing'), isEmpty);
    });

    test('delete creates tombstone', () {
      final n = store.createNote(title: 'tmp');
      store.deleteNote(n.id);
      expect(store.listNotes(), isEmpty);
      final t = store.getNote(n.id)!;
      expect(t.deleted, isTrue);
      expect(t.version['A'], 2);
    });

    test('change log records every mutation and seq grows', () {
      final n = store.createNote();
      final s1 = store.maxSeq;
      store.updateNote(n.id, title: 'a');
      store.deleteNote(n.id);
      expect(store.maxSeq, greaterThan(s1));
      final ops = store.changeLog().map((r) => r['op']).toList();
      expect(ops, ['delete', 'upsert', 'upsert']);
    });

    test('changesSince returns only latest state once', () {
      final a = store.createNote(title: 'a');
      final cursor = store.maxSeq;
      store.updateNote(a.id, title: 'a1');
      store.updateNote(a.id, title: 'a2');
      store.createNote(title: 'b');
      final ch = store.changesSince(cursor);
      expect(ch.notes.map((c) => c.note.title), ['a2', 'b']);
      expect(ch.done, isTrue);
      expect(store.changesSince(store.maxSeq).notes, isEmpty);
    });

    test('settings persist', () {
      store.setSetting('autoSync', 'false');
      expect(store.getSetting('autoSync'), 'false');
      expect(store.getSetting('missing'), isNull);
    });

    test('resolve keepBoth creates a copy', () {
      final local = store.createNote(title: 'L');
      final remote = local.copyWith(
        title: 'R',
        version: VersionVector({'B': 1, ...local.version.entries}).increment('B'),
        lastDevice: 'B',
      );
      // make it concurrent: local edit too
      store.updateNote(local.id, title: 'L2');
      store.upsertPeer(deviceId: 'B', name: 'B', publicKey: [1]);
      store.applyRemoteBatch('B', [RemoteNote(remote)], newCursor: 1);
      final c = store.allConflicts().single;
      store.resolveConflict(c.id, ConflictChoice.keepBoth);
      expect(store.allConflicts(), isEmpty);
      expect(store.listNotes(), hasLength(2));
    });

    test('database survives reopen on disk', () async {
      final dir = await Directory.systemTemp.createTemp('nv');
      final path = '${dir.path}/t.db';
      var s = NoteStore.open(path, deviceId: 'A');
      final n = s.createNote(title: 'persist');
      s.dispose();
      s = NoteStore.open(path, deviceId: 'A');
      expect(s.getNote(n.id)!.title, 'persist');
      s.dispose();
      await dir.delete(recursive: true);
    });
  });
}
