import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../data/attachment_storage.dart';
import '../../data/note_store.dart';
import '../../data/vault/encrypted_attachment_storage.dart';
import '../../data/vault/vault_key.dart';
import '../../domain/attachment.dart';
import '../../domain/note.dart';
import '../crypto/secure_channel.dart';

class NoteTransferProgress {
  final int completedBytes;
  final int totalBytes;
  final bool finalizing;
  const NoteTransferProgress(this.completedBytes, this.totalBytes, {this.finalizing = false});
}

/// Bounded, consent-first transfer on an already authenticated ephemeral channel.
/// Neither side reads or writes permanent pairing information.
class NoteTransfer {
  static const chunkSize = 48 * 1024;
  static const maxTotalBytes = 500 * 1024 * 1024;
  static const maxManifestBytes = 4 * 1024 * 1024;

  static Map<String, Attachment> _validate(List<RemoteNote> items) {
    final validator = NoteStore.inMemory(deviceId: 'transfer-validation');
    try {
      validator.importTransferredNotes(items);
    } finally {
      validator.dispose();
    }
    final hashes = <String, Attachment>{};
    var total = 0;
    for (final item in items) {
      for (final a in item.attachments) {
        final previous = hashes[a.sha256];
        if (previous != null && previous.size != a.size) {
          throw const FormatException('Противоречивые размеры вложений');
        }
        if (previous == null) {
          total += a.size;
          hashes[a.sha256] = a;
        }
      }
    }
    if (total > maxTotalBytes) throw const FormatException('Общий размер передачи больше 500 МБ');
    return hashes;
  }

  static Future<bool> send(SecureChannel channel, List<RemoteNote> items, AttachmentStorage files,
      {void Function(NoteTransferProgress)? onProgress}) async {
    final hashes = _validate(items);
    final manifest = {'t': 'notehub-transfer', 'v': 1, 'notes': [
      for (final item in items) {'note': item.note.toWire(), 'files': [for (final a in item.attachments) a.toWire()]},
    ]};
    if (utf8.encode(jsonEncode(manifest)).length > maxManifestBytes) {
      throw const FormatException('Слишком большой набор заметок');
    }
    // Check availability and integrity before asking the other user to accept.
    for (final a in hashes.values) {
      if (!files.has(a.sha256)) {
        throw const FileSystemException('Вложение отсутствует или повреждено. Сначала загрузите его на это устройство');
      }
      await files.readVerified(a.sha256, size: a.size);
    }
    await channel.send(manifest);
    final reply = await channel.receive(timeout: const Duration(minutes: 5));
    if (reply['t'] == 'declined') return false;
    if (reply['t'] != 'accepted') throw const FormatException('Ожидалось подтверждение приёма');
    final total = hashes.values.fold<int>(0, (sum, a) => sum + a.size);
    var completed = 0;
    onProgress?.call(NoteTransferProgress(0, total));
    for (final a in hashes.values) {
      final content = await files.readVerified(a.sha256, size: a.size);
      try {
        var offset = 0;
        while (offset < a.size) {
          final bytes = content.sublist(offset, (offset + chunkSize).clamp(0, content.length));
          if (bytes.isEmpty) throw const FileSystemException('Файл изменился во время передачи');
          await channel.send({'t': 'chunk', 'hash': a.sha256, 'offset': offset, 'data': base64Encode(bytes)});
          final ack = await channel.receive();
          offset += bytes.length;
          if (ack['t'] != 'ack' || ack['offset'] != offset) throw const FormatException('Ошибка подтверждения блока');
          completed += bytes.length;
          onProgress?.call(NoteTransferProgress(completed, total));
        }
      } finally { content.fillRange(0, content.length, 0); }
    }
    onProgress?.call(NoteTransferProgress(completed, total, finalizing: true));
    await channel.send({'t': 'done'});
    final result = await channel.receive();
    if (result['t'] != 'imported') throw const FormatException('Приём не завершён');
    return true;
  }

  static Future<List<Note>> receive(SecureChannel channel, NoteStore store, AttachmentStorage files,
      {required Future<bool> Function(List<RemoteNote> notes, int bytes) confirm,
      void Function(NoteTransferProgress)? onProgress}) async {
    final manifest = await channel.receive();
    if (manifest['t'] != 'notehub-transfer' || manifest['v'] != 1 ||
        utf8.encode(jsonEncode(manifest)).length > maxManifestBytes) {
      throw const FormatException('Некорректный набор передачи');
    }
    final raw = manifest['notes'];
    if (raw is! List || raw.isEmpty || raw.length > 100) throw const FormatException('Некорректный список заметок');
    final items = <RemoteNote>[];
    for (final entry in raw) {
      final note = Note.fromWire(Map<String, dynamic>.from(entry['note'] as Map));
      final attachments = entry['files'];
      if (attachments is! List || attachments.length > 100) throw const FormatException('Некорректный список вложений');
      items.add(RemoteNote(note, attachments: [for (final a in attachments)
        Attachment.fromWire(Map<String, dynamic>.from(a as Map), noteId: note.id)]));
    }
    final hashes = _validate(items);
    if (!await confirm(List.unmodifiable(items), hashes.values.fold<int>(0, (n, a) => n + a.size))) {
      await channel.send({'t': 'declined'});
      return [];
    }
    await files.root.create(recursive: true);
    final staging = await files.root.createTemp('.notehub-transfer-');
    final stagedFiles = EncryptedAttachmentStorage(staging, await VaultKey.create());
    try {
      await channel.send({'t': 'accepted'});
      final total = hashes.values.fold<int>(0, (sum, a) => sum + a.size);
      var completed = 0;
      onProgress?.call(NoteTransferProgress(0, total));
      for (final a in hashes.values) {
        final output = BytesBuilder(copy: false);
          var offset = 0;
          while (offset < a.size) {
            final message = await channel.receive();
            if (message['t'] != 'chunk' || message['hash'] != a.sha256 || message['offset'] != offset ||
                message['data'] is! String || (message['data'] as String).length > (chunkSize * 4 ~/ 3 + 4)) {
              throw const FormatException('Некорректный блок файла');
            }
            final bytes = base64Decode(message['data'] as String);
            if (bytes.isEmpty || bytes.length > chunkSize || offset + bytes.length > a.size) {
              throw const FormatException('Некорректный размер блока');
            }
            output.add(bytes);
            offset += bytes.length;
            await channel.send({'t': 'ack', 'offset': offset});
            completed += bytes.length;
            onProgress?.call(NoteTransferProgress(completed, total));
          }
        final content = output.takeBytes();
        try {
          if (AttachmentStorage.sha256Of(content) != a.sha256) {
            throw const FormatException('Контрольная сумма вложения не совпадает');
          }
          await stagedFiles.save(content);
        } finally {
          content.fillRange(0, content.length, 0);
        }
      }
      if ((await channel.receive())['t'] != 'done') throw const FormatException('Передача не завершена');
      onProgress?.call(NoteTransferProgress(completed, total, finalizing: true));
      // Only verified complete files enter permanent storage. No notes are
      // visible until every file has arrived and the SQLite transaction commits.
      for (final a in hashes.values) {
        if (files.has(a.sha256)) {
          await files.readVerified(a.sha256, size: a.size);
          continue;
        }
        final content = await stagedFiles.readVerified(a.sha256, size: a.size);
        try {
          await files.save(content);
        } finally {
          content.fillRange(0, content.length, 0);
        }
      }
      final imported = store.importTransferredNotes(items);
      await channel.send({'t': 'imported'});
      return imported;
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }
}
