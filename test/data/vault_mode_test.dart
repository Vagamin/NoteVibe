import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/data/vault/vault_mode.dart';

void main() {
  test('unknown or corrupt storage mode never falls back to plaintext', () async {
    final dir = await Directory.systemTemp.createTemp('notehub-mode-test-');
    addTearDown(() => dir.delete(recursive: true));
    expect(await VaultMode.encrypted(dir), isFalse);
    final marker = File('${dir.path}/storage-mode.json');
    await marker.writeAsString('{"v":1,"mode":"encrypted"}');
    expect(await VaultMode.encrypted(dir), isTrue);
    await marker.writeAsString('{"v":1,"mode":"plain"}');
    expect(await VaultMode.encrypted(dir), isFalse);
    for (final raw in ['invalid', '{"v":2,"mode":"encrypted"}', '{"v":1,"mode":"unknown"}']) {
      await marker.writeAsString(raw);
      await expectLater(VaultMode.encrypted(dir), throwsFormatException);
    }
  });
}
