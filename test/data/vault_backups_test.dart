import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/data/vault/vault_backups.dart';
import 'package:notevibe/data/vault/vault_file.dart';
import 'package:notevibe/data/vault/vault_key.dart';

void main() {
  test('encrypts only owned backups and preserves exact bytes and originals', () async {
    final dir = await Directory.systemTemp.createTemp('notehub-backups-test-');
    addTearDown(() => dir.delete(recursive: true));
    final database = File('${dir.path}/notevibe.db');
    await database.writeAsBytes([0]);
    final original = File('${database.path}.bak-v3');
    await original.writeAsBytes([1, 2, 3, 4]);
    await File('${dir.path}/personal.bak').writeAsBytes([8]);
    await File('${database.path}.bak-v3.extra').writeAsBytes([9]);
    final key = await VaultKey.create();
    final destination = Directory('${dir.path}/encrypted');
    await VaultBackups.prepare(database, destination, key);
    final output = await destination.list().toList();
    expect(output, hasLength(1));
    expect(await VaultFile.read(File(output.single.path), key).expand((bytes) => bytes).toList(), [1, 2, 3, 4]);
    expect(await original.readAsBytes(), [1, 2, 3, 4]);
    final restored = await Directory('${dir.path}/restored').create();
    await VaultBackups.restore(destination, restored, key);
    expect(await File('${restored.path}/notevibe.db.bak-v3').readAsBytes(), [1, 2, 3, 4]);
    await expectLater(VaultBackups.prepare(database, destination, key), throwsA(isA<FileSystemException>()));
  });
}
