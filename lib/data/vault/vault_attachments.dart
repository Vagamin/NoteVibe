import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' show SecretKey;

import '../attachment_storage.dart' show maxAttachmentBytes;
import 'vault_file.dart';

/// Encrypted attachment storage primitive. No plaintext staging files or
/// decrypted file paths are exposed. UI and sync integration is separate.
class VaultAttachments {
  final Directory directory;
  final SecretKey key;
  VaultAttachments(this.directory, this.key);

  File _file(String hash) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) throw const FormatException('Некорректный хеш файла');
    return File('${directory.path}/$hash.nhv');
  }

  Future<bool> has(String hash) async =>
    await FileSystemEntity.type(_file(hash).path, followLinks: false) == FileSystemEntityType.file;

  /// The expected hash/size comes from selected source metadata. Both are
  /// checked before publishing the encrypted file under its permanent name.
  Future<void> save(Stream<List<int>> source, {required String hash, required int size}) async {
    final destination = _file(hash);
    if (size < 0 || size > maxAttachmentBytes) throw const FormatException('Файл больше 100 МБ или имеет некорректный размер');
    if (await has(hash)) {
      // Never skip validation of incoming bytes or silently reuse corruption.
      await readVerified(hash, size: size);
    }
    await directory.create(recursive: true);
    final staging = await directory.createTemp('.attachment-');
    final candidate = File('${staging.path}/payload.nhv');
    final digest = _DigestSink();
    final hashing = sha256.startChunkedConversion(digest);
    var received = 0;
    Stream<List<int>> checked() async* {
      await for (final chunk in source) {
        received += chunk.length;
        if (received > size || received > maxAttachmentBytes) throw const FormatException('Размер файла не совпадает');
        hashing.add(chunk);
        yield chunk;
      }
      hashing.close();
      if (received != size || digest.value?.toString() != hash) {
        throw const FormatException('Контрольная сумма или размер файла не совпадает');
      }
    }
    try {
      await VaultFile.write(candidate, checked(), key);
      if (await has(hash)) {
        await readVerified(hash, size: size);
      } else {
        if (await FileSystemEntity.type(destination.path, followLinks: false) != FileSystemEntityType.notFound) {
          throw const FileSystemException('Недопустимый путь вложения');
        }
        await candidate.rename(destination.path);
      }
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }

  /// Returns bytes only after the complete container, EOF, size and expected
  /// hash are verified. Callers must not display unverified partial plaintext.
  Future<Uint8List> readVerified(String hash, {required int size}) async {
    final bytes = await readVerifiedBounded(hash, maxBytes: size);
    if (bytes.length != size) throw const FormatException('Размер вложения не совпадает');
    return bytes;
  }

  Future<Uint8List> readVerifiedBounded(String hash, {int maxBytes = maxAttachmentBytes}) async {
    final file = _file(hash);
    if (maxBytes < 0 || maxBytes > maxAttachmentBytes) throw const FormatException('Некорректный размер вложения');
    if (!await has(hash)) throw const FileSystemException('Зашифрованное вложение не найдено');
    final builder = BytesBuilder(copy: false);
    await for (final chunk in VaultFile.read(file, key)) {
      if (builder.length + chunk.length > maxBytes) throw const FormatException('Размер вложения не совпадает');
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    if (sha256.convert(bytes).toString() != hash) {
      throw const FormatException('Контрольная сумма вложения не совпадает');
    }
    return bytes;
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
