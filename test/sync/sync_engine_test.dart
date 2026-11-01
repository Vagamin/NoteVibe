import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/domain/conflict.dart';
import 'package:notevibe/sync/engine/sync_engine.dart';

import 'helpers.dart';

void main() {
  late Device a, b;

  setUp(() async {
    a = await Device.create('A');
    // B's clock runs slightly later so "last edit wins" is deterministic.
    b = await Device.create('B', clock: FakeClock(DateTime(2026, 1, 1, 12, 0, 30)));
    a.trust(b);
    b.trust(a);
  });

  tearDown(() {
    a.store.dispose();
    b.store.dispose();
  });

  test('one-way: new notes reach the other device', () async {
    for (var i = 0; i < 5; i++) {
      a.store.createNote(title: 'n$i', plainText: 'text $i');
    }
    final (sa, sb) = await syncPair(a, b);
    expect(sa.sent, 5);
    expect(sb.received, 5);
    expect(b.store.listNotes().map((n) => n.title).toSet(), {'n0', 'n1', 'n2', 'n3', 'n4'});
  });

  test('two-way and only changed notes are transmitted', () async {
    final n1 = a.store.createNote(title: 'from A');
    b.store.createNote(title: 'from B');
    await syncPair(a, b);
    expect(a.store.listNotes(), hasLength(2));
    expect(b.store.listNotes(), hasLength(2));

    // Nothing changed -> nothing sent (no echo back either).
    var (sa, sb) = await syncPair(a, b);
    expect(sa.sent + sb.sent, 0);

    a.store.updateNote(n1.id, title: 'from A edited');
    (sa, sb) = await syncPair(a, b);
    expect(sa.sent, 1);
    expect(sb.sent, 0);
    expect(b.store.getNote(n1.id)!.title, 'from A edited');
    expect(b.store.getNote(n1.id)!.version, a.store.getNote(n1.id)!.version);
  });

  test('sync initiated by the other side works the same', () async {
    final n = b.store.createNote(title: 'phone note');
    await syncPair(a, b);
    a.store.updateNote(n.id, title: 'edited on pc');
    await syncPair(b, a);
    expect(b.store.getNote(n.id)!.title, 'edited on pc');
  });

  test('deletion propagates', () async {
    final n = a.store.createNote(title: 'to delete');
    await syncPair(a, b);
    b.store.deleteNote(n.id);
    await syncPair(a, b);
    expect(a.store.listNotes(), isEmpty);
    expect(a.store.getNote(n.id)!.deleted, isTrue);
  });

  test('concurrent edits produce a conflict, both versions kept', () async {
    final n = a.store.createNote(title: 'base');
    await syncPair(a, b);
    a.store.updateNote(n.id, title: 'edit on A');
    b.store.updateNote(n.id, title: 'edit on B');

    final (sa, sb) = await syncPair(a, b);
    expect(sa.conflicts + sb.conflicts, greaterThan(0));

    // Both converge on the same winner (later edit = B) ...
    final na = a.store.getNote(n.id)!;
    final nb = b.store.getNote(n.id)!;
    expect(na.title, 'edit on B');
    expect(nb.title, 'edit on B');
    expect(na.version, nb.version);
    // ... and both still have the other version as a conflict.
    expect(na.hasConflict, isTrue);
    expect(a.store.conflictsFor(n.id).single.other.title, 'edit on A');
    expect(b.store.conflictsFor(n.id).single.other.title, 'edit on A');
  });

  test('conflict resolution propagates and clears conflict everywhere', () async {
    final n = a.store.createNote(title: 'base');
    await syncPair(a, b);
    a.store.updateNote(n.id, title: 'A');
    b.store.updateNote(n.id, title: 'B');
    await syncPair(a, b);

    final c = a.store.conflictsFor(n.id).single;
    a.store.resolveConflict(c.id, ConflictChoice.takeOther);
    expect(a.store.getNote(n.id)!.title, 'A');
    expect(a.store.conflictCount, 0);

    await syncPair(a, b);
    expect(b.store.getNote(n.id)!.title, 'A');
    expect(b.store.conflictCount, 0);
    // Stable afterwards.
    await syncPair(b, a);
    expect(a.store.conflictCount + b.store.conflictCount, 0);
  });

  test('identical concurrent edits do not create a conflict', () async {
    final n = a.store.createNote(title: 'base');
    await syncPair(a, b);
    a.store.updateNote(n.id, title: 'same');
    b.store.updateNote(n.id, title: 'same');
    await syncPair(a, b);
    expect(a.store.conflictCount + b.store.conflictCount, 0);
  });

  test('edit wins over concurrent delete (no data loss)', () async {
    final n = a.store.createNote(title: 'keep me');
    await syncPair(a, b);
    a.store.deleteNote(n.id);
    b.store.updateNote(n.id, title: 'edited');
    await syncPair(a, b);
    expect(a.store.getNote(n.id)!.deleted, isFalse);
    expect(a.store.getNote(n.id)!.title, 'edited');
    expect(b.store.getNote(n.id)!.deleted, isFalse);
  });

  test('connection drop mid-sync loses nothing and resumes', () async {
    for (var i = 0; i < 9; i++) {
      a.store.createNote(title: 'n$i');
    }
    // Handshake = 2 frames from A, then start, then batches. Drop early.
    await expectLater(syncPair(a, b, dropAfter: 5), throwsA(anything));
    final partial = b.store.listNotes().length;
    expect(partial, lessThan(9));
    // Whatever was applied is consistent (whole batches only).
    expect(partial % 2, 0);

    final (sa, _) = await syncPair(a, b);
    expect(b.store.listNotes(), hasLength(9));
    // Only the remainder was sent on resume.
    expect(sa.sent, 9 - partial);
  });

  test('re-delivery of the same batch is idempotent', () async {
    final n = a.store.createNote(title: 'x');
    await syncPair(a, b);
    final before = b.store.getNote(n.id)!;
    // Force resend by resetting B's cursor.
    final batch = a.store.changesSince(0);
    final r = b.store.applyRemoteBatch('A', batch.notes, newCursor: batch.lastSeq);
    expect(r.applied, 0);
    expect(b.store.getNote(n.id)!.version, before.version);
    expect(b.store.conflictCount, 0);
  });

  test('peer reinstall (new epoch) triggers full resync', () async {
    a.store.createNote(title: 'one');
    a.store.createNote(title: 'two');
    await syncPair(a, b);
    // B reinstalls: fresh DB, same identity.
    b.store.dispose();
    b = await Device.create('B');
    b.trust(a);
    await syncPair(a, b);
    expect(b.store.listNotes(), hasLength(2));
  });

  test('three devices converge', () async {
    final c = await Device.create('C');
    c.trust(a);
    a.trust(c);
    c.trust(b);
    b.trust(c);
    final n = a.store.createNote(title: 'shared');
    await syncPair(a, b);
    await syncPair(b, c);
    c.store.updateNote(n.id, title: 'from C');
    await syncPair(c, a);
    await syncPair(a, b);
    expect(a.store.getNote(n.id)!.title, 'from C');
    expect(b.store.getNote(n.id)!.title, 'from C');
    c.store.dispose();
  });

  test('unpaired peer cannot sync', () async {
    b.store.removePeer('A');
    await expectLater(syncPair(a, b), throwsA(isA<Object>()));
    expect(isNetworkError(Exception()), isFalse);
  });
}
