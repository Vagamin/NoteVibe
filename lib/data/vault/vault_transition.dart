import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../sync/crypto/keys.dart';
import 'vault_backups.dart';
import 'vault_migration.dart';
import 'vault_mode.dart';
import 'vault_session.dart';
import 'vault_key_store.dart';

/// Resumable commit protocol. Preparation never touches the active source.
/// The journal contains no password, paths supplied by users, or note content.
class VaultTransition {
  static File _journal(Directory root) => File(p.join(root.path, 'vault-transition.json'));

  static Future<void> _atomic(File file, Object data) async {
    final candidate = File('${file.path}.next');
    if (await FileSystemEntity.type(candidate.path, followLinks: false) == FileSystemEntityType.link ||
        await FileSystemEntity.type(file.path, followLinks: false) == FileSystemEntityType.link) {
      throw const FileSystemException('Недопустимая ссылка конфигурации');
    }
    await candidate.writeAsString(jsonEncode(data), flush: true);
    await candidate.rename(file.path);
  }

  static Future<String?> pending(Directory root) async {
    final file = _journal(root);
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file || await file.length() > 1024) {
      throw const FormatException('Повреждён журнал переноса');
    }
    final data = jsonDecode(await file.readAsString());
    if (data is! Map || data['v'] != 1 || !['enable', 'disable'].contains(data['operation'])) {
      throw const FormatException('Неизвестный журнал переноса');
    }
    return data['operation'] as String;
  }

  /// Caller holds the application-wide lock and has stopped all writers.
  static Future<void> enable(Directory root, {required String deviceId,
      required String password, required KeyStore keys, required List<Directory> caches}) async {
    if (await pending(root) != null || await VaultMode.encrypted(root)) {
      throw StateError('Сначала завершите предыдущий перенос');
    }
    final target = Directory(p.join(root.path, 'vault'));
    if (await target.exists()) throw const FileSystemException('Каталог vault уже существует');
    await _atomic(_journal(root), {'v': 1, 'operation': 'enable', 'phase': 'preparing'});
    try {
      await VaultMigration.prepare(legacyDatabase: File(p.join(root.path, 'notevibe.db')),
        legacyFiles: root, destination: target, deviceId: deviceId, password: password, sourceKeys: keys);
    } catch (_) {
      await recover(root, deviceId: deviceId, keys: keys, caches: caches);
      rethrow;
    }
    await _atomic(_journal(root), {'v': 1, 'operation': 'enable'});
    await recover(root, deviceId: deviceId, password: password, keys: keys, caches: caches);
  }

  static Future<void> disable(Directory root, {required String deviceId,
      required String password, required KeyStore keys, required List<Directory> caches}) async {
    if (await pending(root) != null || !await VaultMode.encrypted(root)) {
      throw StateError('Сначала завершите предыдущий перенос');
    }
    final destination = Directory(p.join(root.path, 'plain-transition'));
    if (await destination.exists()) throw const FileSystemException('Каталог обратного переноса уже существует');
    await _atomic(_journal(root), {'v': 1, 'operation': 'disable', 'phase': 'preparing'});
    try {
      await VaultMigration.preparePlaintext(source: Directory(p.join(root.path, 'vault')),
        destination: destination, deviceId: deviceId, password: password);
    } catch (_) {
      await recover(root, deviceId: deviceId, keys: keys, caches: caches);
      rethrow;
    }
    await _atomic(_journal(root), {'v': 1, 'operation': 'disable'});
    await recover(root, deviceId: deviceId, password: password, keys: keys, caches: caches);
  }

  static Future<void> _deleteFile(File file) async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.file) throw const FileSystemException('Недопустимый файл очистки');
    await file.delete();
  }

  static Future<void> _deleteDirectory(Directory dir) async {
    final type = await FileSystemEntity.type(dir.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.directory) throw const FileSystemException('Недопустимый каталог очистки');
    // Never traverse links when removing app-owned trees.
    await dir.delete(recursive: true);
  }

  static Future<void> recover(Directory root, {required String deviceId,
      String? password, required KeyStore keys, required List<Directory> caches}) async {
    final operation = await pending(root);
    if (operation == null) return;
    final vaultDir = Directory(p.join(root.path, 'vault'));
    final journal = jsonDecode(await _journal(root).readAsString()) as Map;
    if (journal['phase'] == 'preparing') {
      // No commit has happened: the active source is still complete. Remove
      // interrupted staging, especially plaintext from disabling encryption.
      await for (final entry in root.list(followLinks: false)) {
        final name = p.basename(entry.path);
        if (name.startsWith(operation == 'enable' ? '.notehub-migration-' : '.notehub-decryption-')) {
          await _deleteDirectory(Directory(entry.path));
        }
      }
      await _deleteDirectory(operation == 'enable' ? vaultDir : Directory(p.join(root.path, 'plain-transition')));
      await _deleteFile(_journal(root));
      return;
    }
    if (journal['phase'] != null) throw const FormatException('Неизвестная стадия переноса');
    if (operation == 'enable') {
      if (password == null) throw const VaultLocked();
      // Authenticate and restore the committed snapshot before removing ANY
      // legacy data. Failure leaves originals and journal untouched.
      final session = await VaultSession.unlock(vaultDir, password, deviceId: deviceId);
      late List<String> peers;
      try {
        peers = session.notes.store.listPeers().map((peer) => 'peer_${peer.deviceId}').toList();
        final protectedKeys = VaultKeyStore(Directory(p.join(vaultDir.path, 'keys')), session.notes.snapshots.key);
        for (final name in ['identity_x25519', ...peers]) {
          final bytes = await protectedKeys.read(name);
          if (bytes == null || bytes.length != 32) throw const FormatException('Не проверены ключи переноса');
        }
      } finally { await session.close(); }
      await _atomic(File(p.join(root.path, 'storage-mode.json')), {'v': 1, 'mode': 'encrypted'});
      final database = File(p.join(root.path, 'notevibe.db'));
      for (final backup in await VaultBackups.discover(database)) { await _deleteFile(backup); }
      for (final suffix in ['', '-wal', '-shm', '-journal']) { await _deleteFile(File('${database.path}$suffix')); }
      await _deleteDirectory(Directory(p.join(root.path, 'attachments')));
      for (final cache in caches) { await _deleteDirectory(cache); }
      for (final name in ['identity_x25519', ...peers]) { await keys.delete(name); }
      await _deleteFile(File(p.join(root.path, 'keys.dpapi.json')));
    } else {
      // Replaying rename is idempotent: absent staging files were already moved.
      final staging = Directory(p.join(root.path, 'plain-transition'));
      if (await staging.exists()) {
        await for (final entry in staging.list(followLinks: false)) {
          final name = p.basename(entry.path);
          if (name == 'prepared.json') continue;
          if (!(name == 'notevibe.db' || name == 'keys.dpapi.json' || name == 'attachments' ||
              RegExp(r'^notevibe\.db\.bak-v[0-9]+$').hasMatch(name))) {
            throw const FormatException('Неожиданный файл обратного переноса');
          }
          final target = p.join(root.path, name);
          if (await FileSystemEntity.type(target, followLinks: false) != FileSystemEntityType.notFound) {
            throw const FileSystemException('Файл назначения уже существует');
          }
          if (entry is File) { await entry.rename(target); }
          else if (entry is Directory) { await entry.rename(target); }
          else { throw const FileSystemException('Недопустимая ссылка переноса'); }
        }
      }
      if (!await File(p.join(root.path, 'notevibe.db')).exists() ||
          !await File(p.join(root.path, 'keys.dpapi.json')).exists()) {
        throw const FormatException('Обратный перенос не завершён');
      }
      await _atomic(File(p.join(root.path, 'storage-mode.json')), {'v': 1, 'mode': 'plain'});
      await _deleteDirectory(vaultDir);
      await _deleteDirectory(staging);
    }
    await _deleteFile(_journal(root));
  }
}
