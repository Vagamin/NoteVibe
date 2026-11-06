import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/data/vault/vault_lock.dart';

void main() {
  test('Windows vault lock excludes another handle and releases cleanly', () async {
    final dir = await Directory.systemTemp.createTemp('notehub-lock-test-');
    addTearDown(() => dir.delete(recursive: true));
    final first = await VaultLock.acquire(dir);
    try {
      await expectLater(VaultLock.acquire(dir), throwsA(isA<FileSystemException>()));
    } finally {
      await first.release();
    }
    final second = await VaultLock.acquire(dir);
    await second.release();
    await second.release();
    expect(await File('${dir.path}/vault.lock').exists(), isTrue);
  }, skip: !Platform.isWindows);
}
