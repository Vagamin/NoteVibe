import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;

import '../../data/attachment_storage.dart';
import '../../data/note_store.dart';
import '../../domain/attachment.dart';
import '../../sync/sync_service.dart';

/// Adds, opens and saves attachments. The UI calls only this class.
class AttachmentService {
  final NoteStore store;
  final AttachmentStorage files;
  final SyncService sync;
  AttachmentService(this.store, this.files, this.sync);

  /// Lets the user pick files and attaches them to [noteId]. Returns the
  /// number of attached files; files that are too big are skipped with a message.
  Future<AttachResult> pickAndAttach(String noteId) async {
    final picked = await FilePicker.pickFiles();
    final result = AttachResult();
    for (final f in picked) {
      final path = f.path;
      if (path == null) {
        result.failed.add('${f.name}: не удалось прочитать');
        continue;
      }
      final file = File(path);
      final size = await file.length();
      if (size > maxAttachmentBytes) {
        result.failed.add('${f.name}: больше 50 МБ');
        continue;
      }
      final bytes = await file.readAsBytes();
      final hash = await files.save(bytes);
      store.addAttachment(
        noteId: noteId,
        name: f.name,
        mime: _mimeOf(f.name),
        size: bytes.length,
        sha256: hash,
      );
      result.added++;
    }
    return result;
  }

  Future<void> open(Attachment a) async {
    final file = files.fileFor(a.sha256);
    if (!await file.exists()) throw const FileSystemException('Файл не найден на этом устройстве');
    final tmp = File(p.join(Directory.systemTemp.path, 'notevibe_open', a.name));
    await files.exportTo(a.sha256, tmp);
    await OpenFilex.open(tmp.path, type: a.mime.isEmpty ? null : a.mime);
  }

  /// Saves a copy. If the user set a folder in settings, writes there directly;
  /// otherwise asks the system where to save, starting in Downloads.
  Future<String?> saveCopy(Attachment a) async {
    final bytes = await _verifiedBytes(a);
    final custom = store.getSetting(saveDirSetting);
    if (custom != null && custom.isNotEmpty) {
      final target = _uniqueFile(p.join(custom, a.name));
      await target.writeAsBytes(bytes, flush: true);
      store.setSavedCopy(a.sha256, target.path);
      return target.path;
    }
    final target = await FilePicker.saveFile(
      fileName: a.name,
      bytes: bytes,
      mimeType: a.mime.isEmpty ? 'application/octet-stream' : a.mime,
      dialogTitle: 'Сохранить файл',
      initialDirectory: defaultDownloadsDir,
    );
    if (target != null) store.setSavedCopy(a.sha256, target.toFilePath());
    return target?.toFilePath();
  }

  /// Path of the saved copy, or null when there is no copy on disk.
  String? savedPath(Attachment a) {
    final saved = store.savedCopyPath(a.sha256);
    if (saved == null || !File(saved).existsSync()) return null;
    return saved;
  }

  /// Opens Explorer with the saved copy selected (Windows only).
  Future<void> openLocation(Attachment a) async {
    final saved = savedPath(a);
    if (saved == null) throw const FileSystemException('Копия файла не найдена');
    if (Platform.isWindows) await Process.run('explorer.exe', ['/select,', saved]);
  }

  static const saveDirSetting = 'attachments_dir';

  /// Downloads folder used when no custom folder is set.
  static String get defaultDownloadsDir {
    if (Platform.isAndroid) return '/storage/emulated/0/Download';
    final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.';
    return p.join(home, 'Downloads');
  }

  static File _uniqueFile(String path) {
    var f = File(path);
    final base = p.basenameWithoutExtension(path);
    final ext = p.extension(path);
    var i = 1;
    while (f.existsSync()) {
      f = File(p.join(p.dirname(path), '$base ($i)$ext'));
      i++;
    }
    return f;
  }

  Future<Uint8List> _verifiedBytes(Attachment a) async {
    final file = files.fileFor(a.sha256);
    if (!await file.exists()) throw const FileSystemException('Файл не найден на этом устройстве');
    final bytes = await file.readAsBytes();
    if (AttachmentStorage.sha256Of(bytes) != a.sha256) {
      throw const FileSystemException('Файл повреждён (контрольная сумма не совпадает)');
    }
    return bytes;
  }

  /// Downloads the bytes from a paired device (the attachment is missing here).
  Future<void> download(Attachment a) => sync.fetchAttachment(a);

  /// Deletes the local copy but keeps the metadata. Refused unless another
  /// paired device has the file, so the bytes are never lost.
  Future<void> freeSpace(Attachment a) async {
    if (!store.hasRemoteHolder(a.sha256)) {
      throw const FileSystemException('Нельзя освободить: копии на других устройствах нет');
    }
    await files.delete(a.sha256);
  }

  void remove(Attachment a) {
    store.removeAttachment(a.id);
    // Keep the bytes only if another attachment still uses them.
    final stillUsed = store.allAttachmentHashes().contains(a.sha256);
    if (!stillUsed) files.delete(a.sha256);
  }

  static String _mimeOf(String name) {
    final ext = p.extension(name).toLowerCase();
    return switch (ext) {
      '.jpg' || '.jpeg' => 'image/jpeg',
      '.png' => 'image/png',
      '.gif' => 'image/gif',
      '.webp' => 'image/webp',
      '.heic' => 'image/heic',
      '.pdf' => 'application/pdf',
      '.txt' => 'text/plain',
      '.mp3' => 'audio/mpeg',
      '.mp4' => 'video/mp4',
      '.zip' => 'application/zip',
      _ => 'application/octet-stream',
    };
  }
}

class AttachResult {
  int added = 0;
  final List<String> failed = [];
}
