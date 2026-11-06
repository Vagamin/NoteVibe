import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/data/attachment_storage.dart';
import 'package:notevibe/data/vault/encrypted_attachment_storage.dart';
import 'package:notevibe/data/vault/vault_key.dart';

void main() {
  test('storage adapter supports verified reads but refuses plaintext paths', () async {
    final dir = await Directory.systemTemp.createTemp('notehub-adapter-test-');
    addTearDown(() => dir.delete(recursive: true));
    final AttachmentStorage storage = EncryptedAttachmentStorage(dir, await VaultKey.create());
    final bytes = [1, 2, 3];
    final hash = await storage.save(bytes);
    expect(storage.has(hash), isTrue);
    expect(await storage.readVerified(hash), bytes);
    expect(await storage.readVerified(hash, size: 3), bytes);
    await expectLater(storage.readVerified(hash, size: 2), throwsFormatException);
    expect(() => storage.fileFor(hash), throwsUnsupportedError);
    await expectLater(storage.exportTo(hash, File('${dir.path}/plaintext')), throwsUnsupportedError);
    expect(await File('${dir.path}/plaintext').exists(), isFalse);
    await storage.delete(hash);
    expect(storage.has(hash), isFalse);
  });
}
