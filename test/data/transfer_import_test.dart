import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/data/note_store.dart';
import 'package:notevibe/domain/attachment.dart';

void main() {
  late NoteStore sender;
  late NoteStore receiver;
  setUp(() {
    sender = NoteStore.inMemory(deviceId: 'S');
    receiver = NoteStore.inMemory(deviceId: 'R');
  });
  tearDown(() { sender.dispose(); receiver.dispose(); });

  Attachment file(String id, {String name = 'voice.wav'}) => Attachment(
    id: id, noteId: 'untrusted', name: name, displayName: 'Запись',
    mime: 'audio/wav', size: 10, sha256: 'a' * 64, createdAt: DateTime(2020));

  test('import creates fresh IDs and local history without pairing', () {
    final source = sender.createNote(title: 'Shared', content: '[{"insert":"Hello\\n"}]', plainText: 'untrusted', kind: 'voice');
    final existing = receiver.createNote(title: 'Keep me');
    final item = RemoteNote(source, attachments: [file('same-id')]);
    final first = receiver.importTransferredNotes([item]).single;
    final second = receiver.importTransferredNotes([item]).single;
    expect(first.id, isNot(source.id));
    expect(second.id, isNot(first.id));
    expect(first.plainText, 'Hello\n');
    expect(first.lastDevice, 'R');
    expect(first.kind, 'voice');
    expect(receiver.getNote(existing.id)!.title, 'Keep me');
    final a = receiver.attachmentsFor(first.id).single;
    expect(a.id, isNot('same-id'));
    expect(a.id, isNot(receiver.attachmentsFor(second.id).single.id));
    expect(a.noteId, first.id);
    expect(a.label, 'Запись');
    expect(receiver.listPeers(), isEmpty);
    expect(receiver.conflictCount, 0);
  });

  test('invalid later attachment rolls back the whole accepted batch', () {
    final source = sender.createNote(title: 'Shared');
    final item = RemoteNote(source, attachments: [file('1')]);
    final bad = RemoteNote(source, attachments: [file('2', name: '../escape')]);
    expect(() => receiver.importTransferredNotes([item, bad]), throwsFormatException);
    expect(receiver.listNotes(), isEmpty);
    expect(receiver.allAttachments(), isEmpty);
  });

  test('trash and malformed documents cannot be imported', () {
    final source = sender.createNote();
    expect(() => receiver.importTransferredNotes([RemoteNote(source.copyWith(trashedAt: DateTime.now()))]), throwsFormatException);
    expect(() => receiver.importTransferredNotes([RemoteNote(source.copyWith(content: '[{"retain":4}]'))]), throwsFormatException);
    expect(receiver.listNotes(), isEmpty);
  });
}
