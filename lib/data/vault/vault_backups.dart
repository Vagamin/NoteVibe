import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' show SecretKey;

import 'vault_file.dart';

/// Handles only app-owned pre-migration backups beside the selected database.
/// Never scans arbitrary user backup folders or deletes plaintext originals.
class VaultBackups {
  /// Explicit plaintext restoration when disabling encryption. Caller owns a
  /// private staging directory and removes it on failure.
  static Future<void> restore(Directory source, Directory destination, SecretKey key,
      {String databaseName = 'notevibe.db'}) async {
    if (!await source.exists()) return;
    final pattern = RegExp('^${RegExp.escape(databaseName)}\\.bak-v[0-9]+\\.nhv\$');
    await for (final entry in source.list(followLinks: false)) {
      final name = entry.uri.pathSegments.last;
      if (!pattern.hasMatch(name)) continue;
      if (entry is! File || await FileSystemEntity.type(entry.path, followLinks: false) != FileSystemEntityType.file) {
        throw const FileSystemException('Недопустимый путь резервной копии');
      }
      final target = File('${destination.path}/${name.substring(0, name.length - 4)}');
      if (await FileSystemEntity.type(target.path, followLinks: false) != FileSystemEntityType.notFound) {
        throw const FileSystemException('Резервная копия уже существует');
      }
      final output = await target.open(mode: FileMode.write);
      try {
        await for (final bytes in VaultFile.read(entry, key)) {
          await output.writeFrom(bytes);
        }
        await output.flush();
      } finally { await output.close(); }
    }
  }

  static Future<List<File>> discover(File database) async {
    final basename = database.uri.pathSegments.last;
    final pattern = RegExp('^${RegExp.escape(basename)}\\.bak-v[0-9]+\$');
    final result = <File>[];
    await for (final entry in database.parent.list(followLinks: false)) {
      if (!pattern.hasMatch(entry.uri.pathSegments.last)) continue;
      if (entry is! File || await FileSystemEntity.type(entry.path, followLinks: false) != FileSystemEntityType.file) {
        throw const FileSystemException('Резервная копия не должна быть ссылкой');
      }
      result.add(entry);
    }
    result.sort((a, b) => a.path.compareTo(b.path));
    return result;
  }

  static Future<void> prepare(File database, Directory destination, SecretKey key) async {
    if (await FileSystemEntity.type(destination.path, followLinks: false) != FileSystemEntityType.notFound) {
      throw const FileSystemException('Каталог защищённых резервных копий уже существует');
    }
    final backups = await discover(database);
    await destination.parent.create(recursive: true);
    final staging = await destination.parent.createTemp('.backups-');
    try {
      for (final source in backups) {
        final beforeLength = await source.length();
        final beforeHash = (await sha256.bind(source.openRead()).first).toString();
        final target = File('${staging.path}/${source.uri.pathSegments.last}.nhv');
        await VaultFile.write(target, source.openRead(), key);
        var restoredLength = 0;
        final restoredHash = (await sha256.bind(VaultFile.read(target, key).map((bytes) {
          restoredLength += bytes.length;
          return bytes;
        })).first).toString();
        final afterHash = (await sha256.bind(source.openRead()).first).toString();
        if (restoredLength != beforeLength || restoredHash != beforeHash || afterHash != beforeHash) {
          throw const FormatException('Резервная копия изменилась во время шифрования');
        }
      }
      if (await FileSystemEntity.type(destination.path, followLinks: false) != FileSystemEntityType.notFound) {
        throw const FileSystemException('Каталог резервных копий уже существует');
      }
      await staging.rename(destination.path);
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }
}
