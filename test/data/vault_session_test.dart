import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/data/vault/vault_database.dart';
import 'package:notevibe/data/vault/vault_key.dart';
import 'package:notevibe/data/vault/vault_note_store.dart';
import 'package:notevibe/data/vault/vault_session.dart';
import 'package:notevibe/data/vault/vault_snapshots.dart';

void main() {
  test('unlock refuses wrong password, releases lock and persists on close', () async {
    final dir = await Directory.systemTemp.createTemp('notehub-session-test-');
    addTearDown(() => dir.delete(recursive: true));
    final key = await VaultKey.create();
    await File('${dir.path}/key.json').writeAsString(await VaultKey.wrap(key, 'test-password'));
    final initial = VaultNoteStore(VaultDatabase.create(),
      VaultSnapshots(Directory('${dir.path}/snapshots'), key), deviceId: 'PC');
    initial.store.createNote(title: 'Before unlock');
    await initial.close();
    await expectLater(VaultSession.unlock(dir, 'wrong', deviceId: 'PC'), throwsException);
    final unlocked = await VaultSession.unlock(dir, 'test-password', deviceId: 'PC');
    expect(unlocked.notes.store.listNotes().single.title, 'Before unlock');
    final oldHeader = await File('${dir.path}/key.json').readAsString();
    await expectLater(unlocked.changePassword('wrong', 'new-password'), throwsException);
    expect(await File('${dir.path}/key.json').readAsString(), oldHeader);
    await unlocked.changePassword('test-password', 'new-password');
    unlocked.notes.store.createNote(title: 'After unlock');
    await unlocked.close();
    await expectLater(VaultSession.unlock(dir, 'test-password', deviceId: 'PC'), throwsException);
    final reopened = await VaultSession.unlock(dir, 'new-password', deviceId: 'PC');
    expect(reopened.notes.store.listNotes(), hasLength(2));
    await reopened.close();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
