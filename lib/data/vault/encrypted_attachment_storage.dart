import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../attachment_storage.dart';
import 'vault_attachments.dart';

/// Adapter for existing sync/recording consumers. Deliberately fails closed
/// for plaintext-path APIs until players and thumbnails use memory sources.
class EncryptedAttachmentStorage extends AttachmentStorage {
  final VaultAttachments encrypted;
  EncryptedAttachmentStorage(super.root, SecretKey key)
      : encrypted = VaultAttachments(Directory('${root.path}/attachments'), key);

  String _path(String hash) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) throw const FormatException('Некорректный хеш');
    return '${encrypted.directory.path}/$hash.nhv';
  }

  @override
  bool has(String sha256) => FileSystemEntity.typeSync(_path(sha256), followLinks: false) == FileSystemEntityType.file;

  @override
  File fileFor(String sha256) => throw UnsupportedError('Зашифрованные вложения не имеют открытого пути');

  @override
  Future<String> save(List<int> bytes) async {
    if (bytes.length > maxAttachmentBytes) throw const FormatException('Файл больше 100 МБ');
    final hash = AttachmentStorage.sha256Of(bytes);
    await encrypted.save(Stream.value(bytes), hash: hash, size: bytes.length);
    return hash;
  }

  @override
  Future<Uint8List> readVerified(String hash, {int? size}) async {
    if (size == null) {
      // Protocol fetch requests specify only the hash. Bound the plaintext
      // independently instead of trusting encrypted-file length as clear size.
      return encrypted.readVerifiedBounded(hash);
    }
    return encrypted.readVerified(hash, size: size);
  }

  @override
  Future<void> exportTo(String sha256, File target) => Future.error(
    UnsupportedError('Открытая копия требует явного экспорта пользователем'));

  @override
  Future<void> delete(String sha256) async {
    if (has(sha256)) await File(_path(sha256)).delete();
  }
}
