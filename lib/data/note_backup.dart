import 'dart:typed_data';

import 'attachment_storage.dart';
import 'backup_zip.dart';
import 'note_store.dart';
import 'vault/vault_database.dart';

class NoteBackup {
  static const maxBytes = 512 * 1024 * 1024;

  static Future<Uint8List> export(NoteStore store, AttachmentStorage attachments) async {
    final memory = VaultDatabase.create();
    late Uint8List database;
    try {
      await store.copyDatabase(memory.database);
      final normalized = memory.reopenAfterBackup();
      try { database = normalized.exportBytes(); } finally { normalized.dispose(); }
    } finally { memory.dispose(); }
    final files = <String, Uint8List>{'notevibe.db': database};
    var total = database.length;
    try {
      if (total > maxBytes) throw const FormatException('База больше 512 МБ');
      for (final item in store.backupNotes()) {
        for (final file in item.attachments) {
          final name = 'attachments/${file.sha256}';
          if (files.containsKey(name) || !attachments.has(file.sha256)) continue;
          if (total + file.size > maxBytes) throw const FormatException('Резервная копия больше 512 МБ');
          files[name] = await attachments.readVerified(file.sha256, size: file.size);
          total += file.size;
        }
      }
      final result = BackupZip.encode(files);
      if (result.length > maxBytes) throw const FormatException('Резервная копия больше 512 МБ');
      return result;
    } finally { for (final bytes in files.values) { bytes.fillRange(0, bytes.length, 0); } }
  }

  static List<RemoteNote> readDatabase(Uint8List bytes) {
    if (bytes.length < 100 || bytes.length > maxBytes || String.fromCharCodes(bytes.take(16)) != 'SQLite format 3\x00') {
      throw const FormatException('Выберите базу NoteVibe или резервный ZIP');
    }
    final memory = VaultDatabase.fromBytes(bytes);
    NoteStore? source;
    try {
      if (memory.database.select('PRAGMA integrity_check').single.values.single != 'ok') {
        throw const FormatException('База повреждена');
      }
      source = NoteStore.fromVaultDatabase(memory.database, deviceId: 'backup-reader');
      final notes = source.backupNotes();
      final validation = NoteStore.inMemory(deviceId: 'backup-validation');
      try { validation.importTransferredNotes(notes, backup: true); } finally { validation.dispose(); }
      return notes;
    } finally { source?.dispose(); memory.dispose(); }
  }

  static Future<int> restore(Uint8List bytes, NoteStore store, AttachmentStorage attachments,
      {required bool replace}) async {
    if (bytes.length > maxBytes) throw const FormatException('Файл больше 512 МБ');
    final zip = bytes.length > 4 && bytes[0] == 0x50 && bytes[1] == 0x4b;
    final files = zip ? BackupZip.decode(bytes) : <String, Uint8List>{'notevibe.db': bytes};
    final notes = readDatabase(files['notevibe.db']!);
    // Verify all archive blobs before writing any data or changing notes.
    for (final item in notes) {
      for (final attachment in item.attachments) {
        final content = files['attachments/${attachment.sha256}'];
        if (content != null && (content.length != attachment.size || AttachmentStorage.sha256Of(content) != attachment.sha256)) {
          throw const FormatException('Вложение повреждено');
        }
      }
    }
    for (final entry in files.entries) {
      if (entry.key == 'notevibe.db') continue;
      if (AttachmentStorage.sha256Of(entry.value) != entry.key.substring(12)) throw const FormatException('Неверный хеш файла');
      await attachments.save(entry.value);
    }
    return store.importTransferredNotes(notes, backup: true, replace: replace).length;
  }
}
