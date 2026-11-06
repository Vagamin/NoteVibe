import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/data/attachment_storage.dart';
import 'package:notevibe/data/note_store.dart';
import 'package:notevibe/data/vault/vault_mode.dart';
import 'package:notevibe/data/vault/vault_session.dart';
import 'package:notevibe/data/vault/vault_transition.dart';
import 'package:notevibe/sync/crypto/dpapi_key_store.dart';
import 'package:notevibe/sync/crypto/keys.dart';

void main() {
  test('interrupted plaintext preparation is removed without switching active mode', () async {
    final root = await Directory.systemTemp.createTemp('notehub-preparation-recovery-');
    addTearDown(() => root.delete(recursive: true));
    await File('${root.path}/storage-mode.json').writeAsString('{"v":1,"mode":"encrypted"}');
    final staging = await Directory('${root.path}/.notehub-decryption-interrupted').create();
    await File('${staging.path}/notevibe.db').writeAsString('plaintext fragments');
    final completed = await Directory('${root.path}/plain-transition').create();
    await File('${completed.path}/notevibe.db').writeAsString('plaintext prepared');
    await File('${root.path}/vault-transition.json').writeAsString('{"v":1,"operation":"disable","phase":"preparing"}');
    await VaultTransition.recover(root, deviceId: 'PC', keys: MemoryKeyStore(), caches: []);
    expect(await staging.exists(), isFalse);
    expect(await completed.exists(), isFalse);
    expect(await VaultMode.encrypted(root), isTrue);
    expect(await VaultTransition.pending(root), isNull);
  });

  test('activation cleans originals and reverse activation preserves identity and orphan blobs', () async {
    final root = await Directory.systemTemp.createTemp('notehub-transition-test-');
    addTearDown(() => root.delete(recursive: true));
    final db = File('${root.path}/notevibe.db');
    final store = NoteStore.open(db.path, deviceId: 'PC');
    final note = store.createNote(title: 'Private note');
    store.dispose();
    await db.copy('${db.path}.bak-v1');
    final files = AttachmentStorage(root);
    final orphan = await files.save([1, 2, 3]);
    final cache = await Directory('${root.path}/cache').create();
    await File('${cache.path}/old-preview').writeAsString('Private note');
    final keys = DpapiFileKeyStore(File('${root.path}/keys.dpapi.json'));
    final identity = await DeviceIdentity.loadOrCreate(keys, 'PC', 'Computer');
    await VaultTransition.enable(root, deviceId: 'PC', password: 'test-password', keys: keys, caches: [cache]);
    expect(await VaultMode.encrypted(root), isTrue);
    expect(await db.exists(), isFalse);
    expect(await File('${db.path}.bak-v1').exists(), isFalse);
    expect(await Directory('${root.path}/attachments').exists(), isFalse);
    expect(await cache.exists(), isFalse);
    expect(await keys.read('identity_x25519'), isNull);
    expect(await VaultTransition.pending(root), isNull);
    final session = await VaultSession.unlock(Directory('${root.path}/vault'), 'test-password', deviceId: 'PC');
    expect(session.notes.store.getNote(note.id)!.title, 'Private note');
    expect(await session.attachments.readVerified(orphan), [1, 2, 3]);
    await session.close();
    await expectLater(VaultTransition.disable(root, deviceId: 'PC', password: 'wrong', keys: keys, caches: []), throwsException);
    expect(await VaultMode.encrypted(root), isTrue);
    await VaultTransition.disable(root, deviceId: 'PC', password: 'test-password', keys: keys, caches: []);
    expect(await VaultMode.encrypted(root), isFalse);
    final reopened = NoteStore.open(db.path, deviceId: 'PC');
    expect(reopened.getNote(note.id)!.title, 'Private note');
    reopened.dispose();
    expect(await files.readVerified(orphan), [1, 2, 3]);
    expect(await File('${db.path}.bak-v1').exists(), isTrue);
    final restoredKeys = DpapiFileKeyStore(File('${root.path}/keys.dpapi.json'));
    expect((await DeviceIdentity.loadOrCreate(restoredKeys, 'PC', 'Computer')).publicKey, identity.publicKey);
    expect(await Directory('${root.path}/vault').exists(), isFalse);
  }, skip: !Platform.isWindows);

  test('interrupted cleanup blocks passwordless startup and resumes idempotently', () async {
    final root = await Directory.systemTemp.createTemp('notehub-transition-recovery-');
    addTearDown(() => root.delete(recursive: true));
    final store = NoteStore.open('${root.path}/notevibe.db', deviceId: 'PC');
    store.createNote(title: 'Survives interruption');
    store.dispose();
    final keys = DpapiFileKeyStore(File('${root.path}/keys.dpapi.json'));
    await DeviceIdentity.loadOrCreate(keys, 'PC', 'Computer');
    // A cache path that cannot be removed as a directory simulates a cleanup
    // failure after the marker has been committed.
    final blocked = File('${root.path}/blocked-cache');
    await blocked.writeAsString('blocked');
    await expectLater(VaultTransition.enable(root, deviceId: 'PC', password: 'test-password',
      keys: keys, caches: [Directory(blocked.path)]), throwsA(isA<FileSystemException>()));
    expect(await VaultTransition.pending(root), 'enable');
    await expectLater(VaultTransition.recover(root, deviceId: 'PC', keys: keys, caches: []), throwsA(isA<VaultLocked>()));
    await expectLater(VaultTransition.recover(root, deviceId: 'PC', password: 'wrong', keys: keys, caches: []), throwsException);
    expect(await keys.read('identity_x25519'), isNotNull);
    await blocked.delete();
    await VaultTransition.recover(root, deviceId: 'PC', password: 'test-password', keys: keys, caches: []);
    expect(await VaultTransition.pending(root), isNull);
    expect(await VaultMode.encrypted(root), isTrue);
    expect(jsonDecode(await File('${root.path}/storage-mode.json').readAsString())['mode'], 'encrypted');
  }, skip: !Platform.isWindows);
}
