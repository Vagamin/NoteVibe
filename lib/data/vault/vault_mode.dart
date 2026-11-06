import 'dart:convert';
import 'dart:io';

/// Fixed relative location: configuration cannot redirect unlock to an
/// arbitrary path. Only a later migration activation may write this marker.
class VaultMode {
  static Future<bool> encrypted(Directory root) async {
    final marker = File('${root.path}/storage-mode.json');
    final type = await FileSystemEntity.type(marker.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return false;
    if (type != FileSystemEntityType.file || await marker.length() > 1024) {
      throw const FormatException('Повреждена конфигурация режима хранилища');
    }
    final data = jsonDecode(await marker.readAsString());
    if (data is! Map || data['v'] != 1 || !const ['plain', 'encrypted'].contains(data['mode'])) {
      throw const FormatException('Неизвестный режим хранилища');
    }
    return data['mode'] == 'encrypted';
  }
}

class VaultLocked implements Exception {
  const VaultLocked();
}
