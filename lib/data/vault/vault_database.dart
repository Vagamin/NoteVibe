import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:sqlite3/sqlite3.dart';

import 'vault_file.dart';

/// SQLite lives exclusively in a private RAM-backed VFS. Encrypted immutable
/// snapshots can be restored without ever creating a plaintext database file.
/// This is a storage primitive, not yet the app's persistence coordinator.
class VaultDatabase {
  static int _nextId = 0;
  final InMemoryFileSystem _vfs;
  final Database database;
  bool _closed = false;
  static const _path = '/notehub.db';

  VaultDatabase._(this._vfs, this.database);

  static VaultDatabase create() => _open(null);

  /// SQLite backup copies the WAL-mode header from the source even when the
  /// destination has no WAL. After the backup completes, reopen the standalone
  /// RAM image with rollback-format header bytes (SQLite header offsets 18/19).
  /// All committed pages already came through SQLite's backup API.
  VaultDatabase reopenAfterBackup() {
    if (_closed || !database.autocommit) throw StateError('Backup is not complete');
    final bytes = Uint8List.fromList(_vfs.fileData[_path]!);
    if (bytes.length < 100) throw const FormatException('Некорректная копия базы');
    bytes[18] = 1;
    bytes[19] = 1;
    dispose();
    return _open(bytes);
  }

  static VaultDatabase _open(Uint8List? bytes) {
    final vfs = InMemoryFileSystem(name: 'notehub-vault-${_nextId++}');
    sqlite3.registerVirtualFileSystem(vfs);
    Database? db;
    try {
      if (bytes != null) {
        final opened = vfs.xOpen(Sqlite3Filename(_path), SqlFlag.SQLITE_OPEN_CREATE | SqlFlag.SQLITE_OPEN_READWRITE);
        opened.file.xWrite(bytes, 0);
        opened.file.xClose();
      }
      db = sqlite3.open(_path, vfs: vfs.name);
      db.execute('PRAGMA temp_store=MEMORY; PRAGMA journal_mode=MEMORY; PRAGMA foreign_keys=ON;');
      if (db.select('PRAGMA integrity_check').single.values.single != 'ok') {
        throw const FormatException('Повреждена база в зашифрованном снимке');
      }
      return VaultDatabase._(vfs, db);
    } catch (_) {
      db?.close();
      sqlite3.unregisterVirtualFileSystem(vfs);
      rethrow;
    }
  }

  static Future<VaultDatabase> restore(File snapshot, SecretKey key,
      {int maxBytes = 256 * 1024 * 1024}) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in VaultFile.read(snapshot, key)) {
      if (builder.length + chunk.length > maxBytes) {
        throw const FormatException('Снимок базы превышает допустимый размер');
      }
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    if (bytes.length < 100 || String.fromCharCodes(bytes.take(16)) != 'SQLite format 3\x00') {
      throw const FormatException('Снимок не содержит базу SQLite');
    }
    return _open(bytes);
  }

  Future<void> snapshot(File destination, SecretKey key) async {
    if (_closed) throw StateError('Database is closed');
    if (database.autocommit == false) throw StateError('Cannot snapshot an active transaction');
    // Copy synchronously before yielding so subsequent edits cannot alter this
    // snapshot while encryption is in progress.
    final bytes = Uint8List.fromList(_vfs.fileData[_path]!);
    await VaultFile.write(destination, Stream.value(bytes), key);
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    database.close();
    sqlite3.unregisterVirtualFileSystem(_vfs);
    for (final data in _vfs.fileData.values) {
      data?.fillRange(0, data.length, 0);
    }
    _vfs.fileData.clear();
  }
}
