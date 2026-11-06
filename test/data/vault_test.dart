import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/data/vault/vault_file.dart';
import 'package:notevibe/data/vault/vault_key.dart';

void main() {
  late Directory dir;
  setUp(() async { dir = await Directory.systemTemp.createTemp('notehub-vault-test-'); });
  tearDown(() async { await dir.delete(recursive: true); });

  test('streamed files roundtrip and use unique ciphertext', () async {
    final key = await VaultKey.create();
    final bytes = List.generate(VaultFile.blockSize * 2 + 17, (i) => i % 251);
    final a = File('${dir.path}/a');
    final b = File('${dir.path}/b');
    await VaultFile.write(a, Stream.value(bytes), key);
    await VaultFile.write(b, Stream.value(bytes), key);
    expect(await VaultFile.read(a, key).expand((b) => b).toList(), bytes);
    expect(await a.readAsBytes(), isNot(await b.readAsBytes()));
    expect(await a.length(), greaterThan(bytes.length));
    await expectLater(VaultFile.write(a, Stream.value([1]), key), throwsA(isA<FileSystemException>()));
    final empty = File('${dir.path}/empty');
    await VaultFile.write(empty, const Stream.empty(), key);
    expect(await VaultFile.read(empty, key).toList(), isEmpty);
  });

  test('tamper, wrong key, truncation and trailing data are refused', () async {
    final key = await VaultKey.create();
    final file = File('${dir.path}/file');
    await VaultFile.write(file, Stream.value(List.filled(100, 42)), key);
    final original = await file.readAsBytes();
    await expectLater(VaultFile.read(file, await VaultKey.create()).drain<void>(), throwsA(isA<SecretBoxAuthenticationError>()));
    for (final damaged in [
      [...original]..[20] ^= 1,
      original.sublist(0, original.length - 20),
      [...original, 0],
    ]) {
      await file.writeAsBytes(damaged);
      await expectLater(VaultFile.read(file, key).drain<void>(), throwsException);
    }
  });

  test('failed source leaves no destination or staging files', () async {
    final file = File('${dir.path}/failed');
    await expectLater(VaultFile.write(file, Stream<List<int>>.error(StateError('interrupted')),
      await VaultKey.create()), throwsStateError);
    expect(await dir.list().toList(), isEmpty);
  });

  test('password wraps a random data key, wrong password is refused', () async {
    final key = await VaultKey.create();
    final wrapped = await VaultKey.wrap(key, 'Пароль теста 123');
    expect(wrapped, isNot(contains('Пароль теста')));
    expect(await (await VaultKey.unwrap(wrapped, 'Пароль теста 123')).extractBytes(), await key.extractBytes());
    await expectLater(VaultKey.unwrap(wrapped, 'неверный'), throwsA(isA<SecretBoxAuthenticationError>()));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
