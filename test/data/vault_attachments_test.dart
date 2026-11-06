import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/data/attachment_storage.dart';
import 'package:notevibe/data/vault/vault_attachments.dart';
import 'package:notevibe/data/vault/vault_key.dart';

void main() {
  late Directory dir;
  late VaultAttachments files;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('notehub-encrypted-attachments-test-');
    files = VaultAttachments(dir, await VaultKey.create());
  });
  tearDown(() async { await dir.delete(recursive: true); });

  test('attachments are encrypted and verified without plaintext disk copies', () async {
    final bytes = List.generate(150000, (i) => i % 251);
    final hash = AttachmentStorage.sha256Of(bytes);
    await files.save(Stream.value(bytes), hash: hash, size: bytes.length);
    expect(await files.has(hash), isTrue);
    expect(await files.readVerified(hash, size: bytes.length), bytes);
    final entries = await dir.list().toList();
    expect(entries, hasLength(1));
    expect(entries.single.path.endsWith('$hash.nhv'), isTrue);
    expect(await File(entries.single.path).readAsBytes(), isNot(bytes));
    await files.save(Stream.value(bytes), hash: hash, size: bytes.length);
    expect(await dir.list().length, 1);
  });

  test('bad hash, wrong length and interrupted input never publish files', () async {
    final hash = AttachmentStorage.sha256Of([1, 2, 3]);
    await expectLater(files.save(Stream.value([9, 9, 9]), hash: hash, size: 3), throwsFormatException);
    await expectLater(files.save(Stream.value([1, 2]), hash: hash, size: 3), throwsFormatException);
    await expectLater(files.save(Stream.value([1, 2, 3, 4]), hash: hash, size: 3), throwsFormatException);
    await expectLater(files.save(Stream<List<int>>.error(StateError('interrupted')), hash: hash, size: 3), throwsStateError);
    expect(await dir.list().length, 0);
    await expectLater(files.save(const Stream.empty(), hash: '../escape', size: 0), throwsFormatException);
    await expectLater(files.save(const Stream.empty(), hash: hash, size: maxAttachmentBytes + 1), throwsFormatException);
  });

  test('container substitution is rejected even with the same vault key', () async {
    final a = [1, 2, 3];
    final b = [4, 5, 6];
    final ah = AttachmentStorage.sha256Of(a);
    final bh = AttachmentStorage.sha256Of(b);
    await files.save(Stream.value(a), hash: ah, size: 3);
    await files.save(Stream.value(b), hash: bh, size: 3);
    await File('${dir.path}/$ah.nhv').writeAsBytes(await File('${dir.path}/$bh.nhv').readAsBytes());
    await expectLater(files.readVerified(ah, size: 3), throwsFormatException);
    await expectLater(files.save(Stream.value(a), hash: ah, size: 3), throwsFormatException);
  });
}
