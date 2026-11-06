import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../sync/crypto/keys.dart';
import 'vault_file.dart';

/// Sync identity and trusted-peer keys encrypted by the unlocked vault key.
/// No fallback to OS storage: a missing vault key must never silently rotate
/// an existing device's identity or bypass the password boundary.
class VaultKeyStore implements KeyStore {
  static const _magic = [78, 72, 86, 75, 1]; // NHVK + version
  static const _maxValueLength = 4096;
  static const _maxEnvelopeLength = 5 + 1 + 160 + _maxValueLength;
  final Directory directory;
  final SecretKey key;
  VaultKeyStore(this.directory, this.key);

  File _file(String name) {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,160}$').hasMatch(name)) {
      throw ArgumentError('Некорректное имя ключа');
    }
    return File('${directory.path}/$name.nhv');
  }

  @override
  Future<Uint8List?> read(String name) async {
    final file = _file(name);
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) throw const FileSystemException('Недопустимый файл ключа');
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in VaultFile.read(file, key)) {
      if (bytes.length + chunk.length > _maxEnvelopeLength) throw const FormatException('Повреждён ключ синхронизации');
      bytes.add(chunk);
    }
    // The purpose is inside the authenticated payload, not inferred from the
    // filename. Copying a valid container to another key name must fail closed.
    final envelope = bytes.takeBytes();
    final purpose = ascii.encode(name);
    final offset = _magic.length + 1 + purpose.length;
    if (envelope.length < offset || envelope.length - offset > _maxValueLength ||
        !_magic.asMap().entries.every((entry) => envelope[entry.key] == entry.value) ||
        envelope[_magic.length] != purpose.length ||
        !purpose.asMap().entries.every((entry) => envelope[_magic.length + 1 + entry.key] == entry.value)) {
      throw const FormatException('Назначение или формат ключа синхронизации не совпадает');
    }
    return Uint8List.sublistView(envelope, offset);
  }

  @override
  Future<void> write(String name, List<int> value) async {
    final target = _file(name);
    if (value.length > _maxValueLength) throw ArgumentError('Слишком большой ключ');
    final purpose = ascii.encode(name);
    final envelope = Uint8List.fromList([..._magic, purpose.length, ...purpose, ...value]);
    await directory.create(recursive: true);
    final staging = await directory.createTemp('.key-write-');
    try {
      final candidate = File('${staging.path}/key.nhv');
      await VaultFile.write(candidate, Stream.value(envelope), key);
      if (await FileSystemEntity.type(target.path, followLinks: false) == FileSystemEntityType.link) {
        throw const FileSystemException('Файл ключа не должен быть ссылкой');
      }
      await candidate.rename(target.path);
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }

  @override
  Future<void> delete(String name) async {
    final file = _file(name);
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.file) throw const FileSystemException('Недопустимый файл ключа');
    await file.delete();
  }
}
