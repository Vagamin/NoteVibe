import 'dart:io';

import 'encrypted_attachment_storage.dart';
import 'vault_key.dart';
import 'vault_lock.dart';
import 'vault_note_store.dart';
import 'vault_snapshots.dart';

/// Unlocks an explicitly selected encrypted vault. Does not create services,
/// start networking, or fall back to a legacy plaintext database on failure.
class VaultSession {
  final Directory directory;
  final VaultNoteStore notes;
  final EncryptedAttachmentStorage attachments;
  final VaultLock _lock;
  bool _closed = false;
  bool _changingPassword = false;
  VaultSession._(this.directory, this.notes, this.attachments, this._lock);

  static Future<VaultSession> unlock(Directory directory, String password,
      {required String deviceId}) async {
    if (await FileSystemEntity.type(directory.path, followLinks: false) != FileSystemEntityType.directory) {
      throw const FileSystemException('Зашифрованное хранилище не найдено');
    }
    final lock = await VaultLock.acquire(directory);
    try {
      final header = File('${directory.path}/key.json');
      if (await header.length() > 2048) throw const FormatException('Повреждён заголовок хранилища');
      final key = await VaultKey.unwrap(await header.readAsString(), password);
      final snapshots = VaultSnapshots(Directory('${directory.path}/snapshots'), key);
      final database = await snapshots.restoreLatest();
      try {
        final notes = VaultNoteStore(database, snapshots, deviceId: deviceId);
        return VaultSession._(directory, notes, EncryptedAttachmentStorage(directory, key), lock);
      } catch (_) {
        database.dispose();
        rethrow;
      }
    } catch (_) {
      await lock.release();
      rethrow;
    }
  }

  Future<void> changePassword(String currentPassword, String newPassword) async {
    if (_closed) throw StateError('Хранилище закрыто');
    if (_changingPassword) throw StateError('Изменение пароля уже выполняется');
    _changingPassword = true;
    try {
    final header = File('${directory.path}/key.json');
    if (await header.length() > 2048) throw const FormatException('Повреждён заголовок хранилища');
    final key = await VaultKey.unwrap(await header.readAsString(), currentPassword);
    final wrapped = await VaultKey.wrap(key, newPassword);
    final verified = await VaultKey.unwrap(wrapped, newPassword);
    final expected = await notes.snapshots.key.extractBytes();
    final actual = await verified.extractBytes();
    if (expected.length != actual.length || List.generate(expected.length, (i) => expected[i] ^ actual[i]).fold<int>(0, (a, b) => a | b) != 0) {
      throw const FormatException('Ключ хранилища изменился');
    }
    final staging = await directory.createTemp('.password-change-');
    try {
      final candidate = File('${staging.path}/key.json');
      await candidate.writeAsString(wrapped, flush: true);
      await VaultKey.unwrap(await candidate.readAsString(), newPassword);
      // Same-volume replacement. Never delete the old header first and never
      // keep a backup envelope accessible with the previous password.
      await candidate.rename(header.path);
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
    } finally {
      _changingPassword = false;
    }
  }

  Future<void> verifyPassword(String password) async {
    if (_closed) throw StateError('Хранилище закрыто');
    final header = File('${directory.path}/key.json');
    if (await header.length() > 2048) throw const FormatException('Повреждён заголовок хранилища');
    await VaultKey.unwrap(await header.readAsString(), password);
  }

  /// Stop sync/players before calling. On save failure retain both RAM data and
  /// exclusive lock so another process cannot open a stale snapshot.
  Future<void> close() async {
    if (_closed) return;
    if (_changingPassword) throw StateError('Дождитесь завершения изменения пароля');
    await notes.close();
    await _lock.release();
    _closed = true;
  }
}
