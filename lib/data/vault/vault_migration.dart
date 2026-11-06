import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../note_store.dart';
import '../attachment_storage.dart';
import 'vault_attachments.dart';
import 'vault_database.dart';
import 'vault_key.dart';
import 'vault_snapshots.dart';
import 'vault_lock.dart';
import 'vault_key_store.dart';
import '../../sync/crypto/keys.dart';
import 'vault_backups.dart';
import '../../sync/crypto/dpapi_key_store.dart';

/// Prepares and verifies an encrypted copy, without activating it or deleting
/// legacy data. The caller must stop edits/sync and hold the legacy-store lock.
/// A completed copy is NOT proof that plaintext originals have been removed.
class VaultMigration {
  /// Explicitly requested plaintext export used to prepare disabling encryption.
  /// Does not activate the result or delete/modify encrypted source generations.
  static Future<void> preparePlaintext({required Directory source,
      required Directory destination, required String deviceId, required String password,
      KeyStore Function(Directory staging)? destinationKeys}) async {
    if (await FileSystemEntity.type(source.path, followLinks: false) != FileSystemEntityType.directory ||
        await FileSystemEntity.type(destination.path, followLinks: false) != FileSystemEntityType.notFound) {
      throw const FileSystemException('Недопустимый исходный или целевой каталог');
    }
    final lock = await VaultLock.acquire(source);
    Directory? staging;
    VaultDatabase? memory;
    NoteStore? store;
    try {
      final header = File('${source.path}/key.json');
      if (await header.length() > 2048) throw const FormatException('Повреждён заголовок хранилища');
      final key = await VaultKey.unwrap(await header.readAsString(), password);
      memory = await VaultSnapshots(Directory('${source.path}/snapshots'), key).restoreLatest();
      store = NoteStore.fromVaultDatabase(memory.database, deviceId: deviceId);
      await destination.parent.create(recursive: true);
      staging = await destination.parent.createTemp('.notehub-decryption-');
      final encryptedKeys = VaultKeyStore(Directory('${source.path}/keys'), key);
      final identity = await encryptedKeys.read('identity_x25519');
      if (identity != null) {
        if (destinationKeys == null && !Platform.isWindows && !Platform.isAndroid) {
          throw UnsupportedError('Неподдерживаемая платформа переноса ключей');
        }
        final plainKeys = destinationKeys?.call(staging) ?? (Platform.isAndroid
          ? MemoryKeyStore() : DpapiFileKeyStore(File('${staging.path}/keys.dpapi.json')));
        for (final name in ['identity_x25519', ...store.listPeers().map((p) => 'peer_${p.deviceId}')]) {
          final bytes = await encryptedKeys.read(name);
          if (bytes == null) throw const FormatException('Отсутствует ключ синхронизации для обратной миграции');
          await plainKeys.write(name, bytes);
          final copied = await plainKeys.read(name);
          if (copied == null || copied.length != bytes.length ||
              List.generate(bytes.length, (i) => copied[i] ^ bytes[i]).any((b) => b != 0)) {
            throw const FormatException('Не удалось проверить восстановленный ключ');
          }
        }
      } else if (store.listPeers().isNotEmpty) {
        throw const FormatException('Отсутствует идентичность сопряжённого устройства');
      }
      final output = sqlite3.open('${staging.path}/notevibe.db');
      try {
        await memory.database.backup(output).drain<void>();
        output.execute('PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;');
        if (output.select('PRAGMA integrity_check').single.values.single != 'ok') {
          throw const FormatException('Расшифрованная база повреждена');
        }
      } finally { output.close(); }
      final encrypted = VaultAttachments(Directory('${source.path}/attachments'), key);
      final plain = AttachmentStorage(staging);
      final seen = <String, int>{};
      for (final attachment in store.allAttachments()) {
        final previous = seen[attachment.sha256];
        if (previous != null) {
          if (previous != attachment.size) throw const FormatException('Противоречивые размеры вложений');
          continue;
        }
        seen[attachment.sha256] = attachment.size;
        if (!await encrypted.has(attachment.sha256)) continue;
        final bytes = await encrypted.readVerified(attachment.sha256, size: attachment.size);
        try {
          await plain.save(bytes);
          await plain.readVerified(attachment.sha256, size: attachment.size);
        } finally { bytes.fillRange(0, bytes.length, 0); }
      }
      final blobDirectory = Directory('${source.path}/attachments');
      if (await blobDirectory.exists()) {
        await for (final entry in blobDirectory.list(followLinks: false)) {
          final name = entry.uri.pathSegments.last;
          if (entry is! File || !RegExp(r'^[a-f0-9]{64}\.nhv$').hasMatch(name)) {
            throw const FormatException('Неизвестный защищённый файл вложения');
          }
          final hash = name.substring(0, 64);
          if (!seen.containsKey(hash)) {
            final bytes = await encrypted.readVerifiedBounded(hash);
            try { await plain.save(bytes); }
            finally { bytes.fillRange(0, bytes.length, 0); }
          }
        }
      }
      final verification = NoteStore.open('${staging.path}/notevibe.db', deviceId: deviceId);
      verification.dispose();
      await VaultBackups.restore(Directory('${source.path}/backups'), staging, key);
      await File('${staging.path}/prepared.json').writeAsString(
        '{"version":1,"state":"prepared-plaintext","encryptedSourceRetained":true}', flush: true);
      if (await FileSystemEntity.type(destination.path, followLinks: false) != FileSystemEntityType.notFound) {
        throw const FileSystemException('Целевое хранилище уже существует');
      }
      await staging.rename(destination.path);
    } finally {
      store?.dispose();
      memory?.dispose();
      try {
        if (staging != null && await staging.exists()) await staging.delete(recursive: true);
      } finally { await lock.release(); }
    }
  }

  static Future<void> prepare({required File legacyDatabase,
      required Directory legacyFiles, required Directory destination,
      required String deviceId, required String password, KeyStore? sourceKeys}) async {
    if (await FileSystemEntity.type(destination.path, followLinks: false) != FileSystemEntityType.notFound) {
      throw const FileSystemException('Целевое хранилище уже существует');
    }
    if (!await legacyDatabase.exists()) throw const FileSystemException('Исходная база не найдена');
    await destination.parent.create(recursive: true);
    final staging = await destination.parent.createTemp('.notehub-migration-');
    VaultDatabase? memory;
    NoteStore? store;
    Database? legacy;
    try {
      final key = await VaultKey.create();
      final wrapped = await VaultKey.wrap(key, password);
      // Verify the password envelope before spending time copying user files.
      final unlocked = await VaultKey.unwrap(wrapped, password);
      memory = VaultDatabase.create();
      legacy = sqlite3.open(legacyDatabase.path, mode: OpenMode.readOnly);
      // SQLite backup includes committed WAL content and never checkpoints or
      // rewrites the original DB. The destination VFS is entirely RAM-backed.
      // Native :memory: normalizes the source WAL header before copying into
      // the RAM VFS, which deliberately has no shared-memory/WAL support.
      final normalized = sqlite3.copyIntoMemory(legacy);
      try {
        normalized.execute('PRAGMA journal_mode=MEMORY; PRAGMA temp_store=MEMORY;');
        await normalized.backup(memory.database).drain<void>();
      } finally {
        normalized.close();
      }
      legacy.close();
      legacy = null;
      memory = memory.reopenAfterBackup();
      memory.database.execute('PRAGMA journal_mode=MEMORY; PRAGMA temp_store=MEMORY;');
      store = NoteStore.fromVaultDatabase(memory.database, deviceId: deviceId);
      if (sourceKeys != null) {
        final encryptedKeys = VaultKeyStore(Directory('${staging.path}/keys'), unlocked);
        for (final name in ['identity_x25519', ...store.listPeers().map((p) => 'peer_${p.deviceId}')]) {
          final bytes = await sourceKeys.read(name);
          if (bytes == null) throw const FormatException('Отсутствует ключ синхронизации для миграции');
          await encryptedKeys.write(name, bytes);
          final copied = await encryptedKeys.read(name);
          if (copied == null || copied.length != bytes.length ||
              List.generate(bytes.length, (i) => copied[i] ^ bytes[i]).any((b) => b != 0)) {
            throw const FormatException('Не удалось проверить перенесённый ключ');
          }
        }
      }
      final attachments = store.allAttachments();
      final encrypted = VaultAttachments(Directory('${staging.path}/attachments'), unlocked);
      final seen = <String, int>{};
      for (final attachment in attachments) {
        final previous = seen[attachment.sha256];
        if (previous != null) {
          if (previous != attachment.size) throw const FormatException('Противоречивые размеры вложений');
          continue;
        }
        seen[attachment.sha256] = attachment.size;
        // Validate hash before using it in a filesystem path.
        if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(attachment.sha256)) {
          throw const FormatException('Некорректный хеш вложения');
        }
        final source = File('${legacyFiles.path}/attachments/${attachment.sha256}');
        final type = await FileSystemEntity.type(source.path, followLinks: false);
        // Missing on-demand attachments remain metadata-only, as before.
        if (type == FileSystemEntityType.notFound) continue;
        if (type != FileSystemEntityType.file) throw const FileSystemException('Недопустимый путь исходного вложения');
        await encrypted.save(source.openRead(), hash: attachment.sha256, size: attachment.size);
        await encrypted.readVerified(attachment.sha256, size: attachment.size);
      }
      final snapshots = VaultSnapshots(Directory('${staging.path}/snapshots'), unlocked);
      // Preserve cached/orphaned blobs too: old database backups can reference
      // attachments absent from the current database. Never discard them.
      final legacyAttachments = Directory('${legacyFiles.path}/attachments');
      if (await legacyAttachments.exists()) {
        await for (final entry in legacyAttachments.list(followLinks: false)) {
          final hash = entry.uri.pathSegments.last;
          if (entry is! File || !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
            throw const FormatException('Неизвестный файл в каталоге вложений. Перенос остановлен без очистки');
          }
          if (!seen.containsKey(hash)) {
            final size = await entry.length();
            await encrypted.save(entry.openRead(), hash: hash, size: size);
            await encrypted.readVerified(hash, size: size);
          }
        }
      }
      await VaultBackups.prepare(legacyDatabase, Directory('${staging.path}/backups'), unlocked);
      await snapshots.save(memory);
      final restored = await snapshots.restoreLatest();
      restored.dispose();
      await File('${staging.path}/key.json').writeAsString(wrapped, flush: true);
      // Only opaque format/state metadata, never note content or the password.
      await File('${staging.path}/prepared.json').writeAsString(
        '{"version":1,"state":"prepared","legacyCleanupRequired":true}', flush: true);
      store.dispose(); store = null;
      memory.dispose(); memory = null;
      if (await FileSystemEntity.type(destination.path, followLinks: false) != FileSystemEntityType.notFound) {
        throw const FileSystemException('Целевое хранилище уже существует');
      }
      await staging.rename(destination.path);
    } finally {
      legacy?.close();
      store?.dispose();
      memory?.dispose();
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }
}
