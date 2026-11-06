import 'dart:convert';
import 'dart:typed_data';

/// Bounded ZIP STORE container. No filesystem extraction or arbitrary paths.
class BackupZip {
  static int crc(List<int> bytes) {
    var value = 0xffffffff;
    for (final byte in bytes) {
      value ^= byte;
      for (var i = 0; i < 8; i++) { value = (value >>> 1) ^ ((value & 1) == 1 ? 0xedb88320 : 0); }
    }
    return value ^ 0xffffffff;
  }

  static Uint8List encode(Map<String, Uint8List> files) {
    final output = BytesBuilder(copy: false);
    final central = BytesBuilder(copy: false);
    for (final entry in files.entries) {
      final name = utf8.encode(entry.key);
      final offset = output.length;
      final checksum = crc(entry.value);
      final header = ByteData(30)..setUint32(0, 0x04034b50, Endian.little)
        ..setUint16(4, 20, Endian.little)..setUint16(6, 0x800, Endian.little)
        ..setUint32(14, checksum, Endian.little)..setUint32(18, entry.value.length, Endian.little)
        ..setUint32(22, entry.value.length, Endian.little)..setUint16(26, name.length, Endian.little);
      output.add(header.buffer.asUint8List()); output.add(name); output.add(entry.value);
      final record = ByteData(46)..setUint32(0, 0x02014b50, Endian.little)
        ..setUint16(4, 20, Endian.little)..setUint16(6, 20, Endian.little)..setUint16(8, 0x800, Endian.little)
        ..setUint32(16, checksum, Endian.little)..setUint32(20, entry.value.length, Endian.little)
        ..setUint32(24, entry.value.length, Endian.little)..setUint16(28, name.length, Endian.little)
        ..setUint32(42, offset, Endian.little);
      central.add(record.buffer.asUint8List()); central.add(name);
    }
    final offset = output.length;
    final size = central.length;
    output.add(central.takeBytes());
    final end = ByteData(22)..setUint32(0, 0x06054b50, Endian.little)
      ..setUint16(8, files.length, Endian.little)..setUint16(10, files.length, Endian.little)
      ..setUint32(12, size, Endian.little)..setUint32(16, offset, Endian.little);
    output.add(end.buffer.asUint8List());
    return output.takeBytes();
  }

  static Map<String, Uint8List> decode(Uint8List bytes) {
    final result = <String, Uint8List>{};
    final data = ByteData.sublistView(bytes);
    var offset = 0;
    while (offset + 30 <= bytes.length && data.getUint32(offset, Endian.little) == 0x04034b50) {
      final flags = data.getUint16(offset + 6, Endian.little);
      final size = data.getUint32(offset + 18, Endian.little);
      final length = data.getUint16(offset + 26, Endian.little);
      final extra = data.getUint16(offset + 28, Endian.little);
      final start = offset + 30 + length + extra;
      if (flags & ~0x800 != 0 || data.getUint16(offset + 8, Endian.little) != 0 ||
          size != data.getUint32(offset + 22, Endian.little) || start + size > bytes.length || result.length > 10000) {
        throw const FormatException('Используйте ZIP, созданный NoteVibe');
      }
      final name = utf8.decode(bytes.sublist(offset + 30, offset + 30 + length));
      if (result.containsKey(name) || !(name == 'notevibe.db' || RegExp(r'^attachments/[a-f0-9]{64}$').hasMatch(name))) {
        throw const FormatException('Неизвестный или повторный файл в резервной копии');
      }
      final content = Uint8List.sublistView(bytes, start, start + size);
      if (crc(content) != data.getUint32(offset + 14, Endian.little)) throw const FormatException('Повреждён ZIP');
      result[name] = content;
      offset = start + size;
    }
    if (!result.containsKey('notevibe.db') || offset + 4 > bytes.length || data.getUint32(offset, Endian.little) != 0x02014b50) {
      throw const FormatException('Некорректный архив резервной копии');
    }
    return result;
  }
}
