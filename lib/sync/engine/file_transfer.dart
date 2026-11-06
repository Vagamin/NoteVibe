import 'dart:convert';
import 'dart:typed_data';

import '../../data/attachment_storage.dart';
import '../../domain/attachment.dart';
import '../crypto/secure_channel.dart';
import 'sync_engine.dart';

const _chunkSize = 256 * 1024;
final _shaPattern = RegExp(r'^[0-9a-f]{64}$');

/// The device answered, but it does not have the file.
class AttachmentMissingError implements Exception {}

/// Serves one attachment over a `fetch` session. Only paired devices reach
/// this point, and only files named by a valid SHA-256 are read.
Future<void> serveAttachment(SecureChannel ch, AttachmentStorage? files) async {
  final m = await ch.receive();
  final sha = m['sha'];
  if (m['t'] != 'get' || files == null || sha is! String || !_shaPattern.hasMatch(sha)) {
    await ch.send({'t': 'error', 'msg': 'nofile'});
    return;
  }
  if (!files.has(sha)) {
    await ch.send({'t': 'error', 'msg': 'nofile'});
    return;
  }
  final bytes = await files.readVerified(sha);
  await ch.send({'t': 'file', 'size': bytes.length});
  for (var off = 0; off < bytes.length; off += _chunkSize) {
    final end = off + _chunkSize > bytes.length ? bytes.length : off + _chunkSize;
    await ch.send({'t': 'chunk', 'd': base64Encode(bytes.sublist(off, end))});
  }
  await ch.send({'t': 'end'});
  await ch.receive(timeout: const Duration(seconds: 15));
}

/// Downloads [a] over a `fetch` session, verifies the SHA-256 and stores it.
/// Nothing is stored unless the hash matches.
Future<void> requestAttachment(SecureChannel ch, Attachment a, AttachmentStorage files, {void Function(int received)? onProgress}) async {
  await ch.send({'t': 'get', 'sha': a.sha256});
  final head = await ch.receive(timeout: const Duration(seconds: 15));
  if (head['t'] == 'error') throw AttachmentMissingError();
  if (head['t'] != 'file') throw SyncProtocolException('неожиданный ответ: ${head['t']}');
  final size = (head['size'] as num).toInt();
  if (size != a.size || size > maxAttachmentBytes) {
    throw SyncProtocolException('размер файла не совпадает');
  }
  final out = BytesBuilder(copy: false);
  while (true) {
    final m = await ch.receive();
    if (m['t'] == 'end') {
      await ch.send({'t': 'bye'});
      break;
    }
    if (m['t'] != 'chunk') throw SyncProtocolException('неожиданный кадр: ${m['t']}');
    out.add(base64Decode(m['d'] as String));
    if (out.length > size) throw SyncProtocolException('файл больше ожидаемого');
    onProgress?.call(out.length);
  }
  final bytes = out.takeBytes();
  if (bytes.length != size) throw SyncProtocolException('файл получен не полностью');
  if (AttachmentStorage.sha256Of(bytes) != a.sha256) {
    throw SyncProtocolException('контрольная сумма не совпадает');
  }
  await files.save(bytes);
}
