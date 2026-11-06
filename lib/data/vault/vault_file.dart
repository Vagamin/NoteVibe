import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'vault_key.dart';

/// Streaming encrypted container. Each block and the mandatory EOF marker are
/// authenticated, binding order and file identity. Plaintext never touches disk.
/// Callers must consume read() to completion to detect a truncated container.
class VaultFile {
  static const blockSize = 64 * 1024;
  static const _magic = [78, 72, 86, 70, 1]; // NHVF + version
  static final _cipher = AesGcm.with256bits();

  static Uint8List _nonce(List<int> prefix, int index) =>
    (ByteData(12)..buffer.asUint8List().setRange(0, 8, prefix)..setUint32(8, index)).buffer.asUint8List();

  static List<int> _aad(List<int> header, int index, bool end) => [
    ...header, ...(ByteData(4)..setUint32(0, index)).buffer.asUint8List(), end ? 1 : 0,
  ];

  /// Only encrypted bytes are written, to an exclusively created staging file.
  /// Refuses to overwrite an existing destination or follow a destination link.
  static Future<void> write(File destination, Stream<List<int>> source, SecretKey key) async {
    if (await FileSystemEntity.type(destination.path, followLinks: false) != FileSystemEntityType.notFound) {
      throw const FileSystemException('Зашифрованный файл уже существует');
    }
    await destination.parent.create(recursive: true);
    final staging = await destination.parent.createTemp('.notehub-encrypted-');
    final temp = File('${staging.path}/payload');
    final output = await temp.open(mode: FileMode.write);
    final prefix = VaultKey.randomBytes(8);
    final header = [..._magic, ...prefix];
    var index = 0;
    var outputClosed = false;
    Future<void> emit(List<int> clear, bool end) async {
      if (index >= 0xffffffff) throw const FormatException('Слишком большой зашифрованный файл');
      final box = await _cipher.encrypt(clear, secretKey: key, nonce: _nonce(prefix, index),
        aad: _aad(header, index, end));
      final length = ByteData(4)..setUint32(0, clear.length);
      await output.writeFrom(length.buffer.asUint8List());
      await output.writeFrom(box.cipherText);
      await output.writeFrom(box.mac.bytes);
      index++;
    }
    try {
      await output.writeFrom(header);
      await for (final incoming in source) {
        for (var start = 0; start < incoming.length; start += blockSize) {
          final end = (start + blockSize).clamp(0, incoming.length);
          await emit(incoming.sublist(start, end), false);
        }
      }
      await emit(const [], true);
      await output.flush();
      await output.close();
      outputClosed = true;
      if (await FileSystemEntity.type(destination.path, followLinks: false) != FileSystemEntityType.notFound) {
        throw const FileSystemException('Зашифрованный файл уже существует');
      }
      await temp.rename(destination.path);
    } finally {
      if (!outputClosed) await output.close();
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }

  static Stream<List<int>> read(File file, SecretKey key) async* {
    final input = await file.open();
    Future<Uint8List> exact(int count) async {
      final bytes = await input.read(count);
      if (bytes.length != count) throw const FormatException('Зашифрованный файл обрезан');
      return bytes;
    }
    try {
      final header = await exact(13);
      for (var i = 0; i < _magic.length; i++) {
        if (header[i] != _magic[i]) throw const FormatException('Неизвестный формат зашифрованного файла');
      }
      final prefix = header.sublist(5);
      var index = 0;
      while (true) {
        final length = ByteData.sublistView(await exact(4)).getUint32(0);
        if (length > blockSize || index >= 0xffffffff) throw const FormatException('Некорректный блок');
        final bytes = await exact(length + 16);
        final clear = await _cipher.decrypt(SecretBox(bytes.sublist(0, length),
          nonce: _nonce(prefix, index), mac: Mac(bytes.sublist(length))),
          secretKey: key, aad: _aad(header, index, length == 0));
        index++;
        if (length == 0) {
          if ((await input.read(1)).isNotEmpty) throw const FormatException('Лишние данные после конца файла');
          break;
        }
        yield clear;
      }
    } finally { await input.close(); }
  }
}
