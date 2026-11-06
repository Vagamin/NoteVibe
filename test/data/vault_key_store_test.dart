import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/data/vault/vault_key.dart';
import 'package:notevibe/data/vault/vault_key_store.dart';
import 'package:notevibe/data/vault/vault_file.dart';
import 'package:notevibe/sync/crypto/keys.dart';

void main() {
  test('encrypted sync keys preserve device identity and reject wrong vault key', () async {
    final dir = await Directory.systemTemp.createTemp('notehub-key-store-test-');
    addTearDown(() => dir.delete(recursive: true));
    final key = await VaultKey.create();
    final store = VaultKeyStore(dir, key);
    final identity = await DeviceIdentity.loadOrCreate(store, 'PC', 'Computer');
    final reopened = await DeviceIdentity.loadOrCreate(VaultKeyStore(dir, key), 'PC', 'Computer');
    expect(reopened.publicKey, identity.publicKey);
    await expectLater(VaultKeyStore(dir, await VaultKey.create()).read('identity_x25519'), throwsException);
    await store.write('peer_PHONE', [1, 2, 3]);
    await store.write('peer_PHONE', [4, 5, 6]);
    expect(await store.read('peer_PHONE'), [4, 5, 6]);
    await store.delete('peer_PHONE');
    expect(await store.read('peer_PHONE'), isNull);
    await expectLater(store.write('../escape', [1]), throwsArgumentError);
    expect((await dir.list().toList()).every((e) => e.path.endsWith('.nhv')), isTrue);
  });
  test('rejects valid encrypted keys copied to a different purpose', () async {
    final dir = await Directory.systemTemp.createTemp('notehub-key-purpose-test-');
    addTearDown(() => dir.delete(recursive: true));
    final key = await VaultKey.create();
    final store = VaultKeyStore(dir, key);
    await store.write('identity_x25519', List.filled(32, 1));
    await store.write('peer_PHONE', List.filled(32, 2));
    final identity = File('${dir.path}/identity_x25519.nhv');
    final original = await identity.readAsBytes();
    await File('${dir.path}/peer_PHONE.nhv').copy(identity.path);
    await expectLater(store.read('identity_x25519'), throwsFormatException);
    await identity.writeAsBytes(original);
    expect(await store.read('identity_x25519'), List.filled(32, 1));

    // No permissive fallback to legacy unbound payloads or another vault file.
    final unbound = File('${dir.path}/peer_OTHER.nhv');
    await VaultFile.write(unbound, Stream.value(List.filled(32, 3)), key);
    await expectLater(store.read('peer_OTHER'), throwsFormatException);
    await store.write('empty', []);
    expect(await store.read('empty'), isEmpty);
    await store.write('maximum', List.filled(4096, 4));
    expect(await store.read('maximum'), List.filled(4096, 4));
    await expectLater(store.write('maximum', List.filled(4097, 4)), throwsArgumentError);
    expect(await store.read('maximum'), List.filled(4096, 4));
  });
}
