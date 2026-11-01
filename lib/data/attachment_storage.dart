import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Maximum attachment size accepted on this device.
const maxAttachmentBytes = 50 * 1024 * 1024;

/// Keeps attachment bytes in `<data>/attachments/<sha256>`. Identical files are
/// stored once; the name is the hash, so a damaged file is detectable.
class AttachmentStorage {
  final Directory root;
  AttachmentStorage(this.root);

  Directory get _dir => Directory(p.join(root.path, 'attachments'));

  File fileFor(String sha256) => File(p.join(_dir.path, sha256));

  bool has(String sha256) => fileFor(sha256).existsSync();

  /// Saves [bytes] and returns the hash. Throws if the file is too large.
  Future<String> save(List<int> bytes) async {
    if (bytes.length > maxAttachmentBytes) {
      throw const FormatException('Файл больше 50 МБ');
    }
    final hash = sha256.convert(bytes).toString();
    final f = fileFor(hash);
    if (!await f.exists()) {
      await _dir.create(recursive: true);
      final tmp = File('${f.path}.part');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(f.path);
    }
    return hash;
  }

  /// Copies the bytes of a stored attachment to [target] and verifies the hash.
  Future<void> exportTo(String sha256, File target) async {
    final src = fileFor(sha256);
    if (!await src.exists()) throw const FileSystemException('Файл не найден на этом устройстве');
    final hash = sha256Of(await src.readAsBytes());
    if (hash != sha256) throw const FileSystemException('Файл повреждён (контрольная сумма не совпадает)');
    await target.parent.create(recursive: true);
    await src.copy(target.path);
  }

  Future<void> delete(String sha256) async {
    final f = fileFor(sha256);
    if (await f.exists()) await f.delete();
  }

  static String sha256Of(List<int> bytes) => sha256.convert(bytes).toString();
}
