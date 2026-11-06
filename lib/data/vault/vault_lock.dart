import 'dart:io';

/// Held for the entire unlocked vault lifetime, not just while saving a file.
/// The OS releases the lock on process termination. Never delete the lock file:
/// doing so could allow two processes to lock different underlying files.
class VaultLock {
  final RandomAccessFile _handle;
  bool _released = false;
  VaultLock._(this._handle);

  static Future<VaultLock> acquire(Directory directory) async {
    await directory.create(recursive: true);
    final file = File('${directory.path}/vault.lock');
    if (await FileSystemEntity.type(file.path, followLinks: false) == FileSystemEntityType.link) {
      throw const FileSystemException('Файл блокировки не должен быть ссылкой');
    }
    final handle = await file.open(mode: FileMode.append);
    try {
      await handle.lock(FileLock.exclusive, 0, 1);
      return VaultLock._(handle);
    } catch (_) {
      await handle.close();
      throw const FileSystemException('Хранилище уже открыто другим экземпляром приложения');
    }
  }

  Future<void> release() async {
    if (_released) return;
    _released = true;
    try {
      await _handle.unlock(0, 1);
    } finally {
      await _handle.close();
    }
  }
}
