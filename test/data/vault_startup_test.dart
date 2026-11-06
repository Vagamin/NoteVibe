import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/data/note_store.dart';
import 'package:notevibe/data/vault/vault_key.dart';
import 'package:notevibe/data/vault/vault_key_store.dart';
import 'package:notevibe/data/vault/vault_migration.dart';
import 'package:notevibe/data/vault/vault_mode.dart';
import 'package:notevibe/sync/crypto/keys.dart';
import 'package:notevibe/ui/providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('encrypted app startup requires password and preserves device identity', () async {
    final dir = await Directory.systemTemp.createTemp('notehub-startup-test-');
    addTearDown(() => dir.delete(recursive: true));
    final legacyFile = File('${dir.path}/notevibe.db');
    final legacy = NoteStore.open(legacyFile.path, deviceId: 'PC');
    final note = legacy.createNote(title: 'Protected note');
    legacy.dispose();
    final sourceKeys = MemoryKeyStore();
    final identity = await DeviceIdentity.loadOrCreate(sourceKeys, 'PC', 'Computer');
    await File('${dir.path}/device_id').writeAsString('PC');
    await VaultMigration.prepare(legacyDatabase: legacyFile, legacyFiles: dir,
      destination: Directory('${dir.path}/vault'), deviceId: 'PC', password: 'Startup password', sourceKeys: sourceKeys);
    await File('${dir.path}/storage-mode.json').writeAsString('{"v":1,"mode":"encrypted"}');
    final args = ['--data-dir', dir.path];
    await expectLater(AppServices.init(args), throwsA(isA<VaultLocked>()));
    await expectLater(AppServices.init(args, 'wrong'), throwsException);
    final services = await AppServices.init(args, 'Startup password');
    try {
      expect(services.vault, isNotNull);
      expect(services.store.getNote(note.id)!.title, 'Protected note');
      expect(services.sync.identity.publicKey, identity.publicKey);
    } finally {
      await services.close();
    }
    // Inject damaged encrypted identity: startup must fail but release its lock.
    final vaultDir = Directory('${dir.path}/vault');
    final key = await VaultKey.unwrap(await File('${vaultDir.path}/key.json').readAsString(), 'Startup password');
    final keys = VaultKeyStore(Directory('${vaultDir.path}/keys'), key);
    await keys.write('identity_x25519', [1]);
    await expectLater(AppServices.init(args, 'Startup password'), throwsException);
    await keys.write('identity_x25519', (await sourceKeys.read('identity_x25519'))!);
    final retried = await AppServices.init(args, 'Startup password');
    await retried.close();
  }, skip: !Platform.isWindows, timeout: const Timeout(Duration(minutes: 3)));
}
