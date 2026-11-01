import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'keys.dart';

final class _Blob extends Struct {
  @Uint32()
  external int cbData;
  external Pointer<Uint8> pbData;
}

typedef _CryptNative = Int32 Function(Pointer<_Blob>, Pointer<Utf16>, Pointer<_Blob>,
    Pointer<Void>, Pointer<Void>, Uint32, Pointer<_Blob>);
typedef _CryptDart = int Function(Pointer<_Blob>, Pointer<Utf16>, Pointer<_Blob>,
    Pointer<Void>, Pointer<Void>, int, Pointer<_Blob>);

/// Windows DPAPI (CryptProtectData), bound to the current Windows user.
class Dpapi {
  static final _crypt32 = DynamicLibrary.open('crypt32.dll');
  static final _kernel32 = DynamicLibrary.open('kernel32.dll');
  static final _protect = _crypt32.lookupFunction<_CryptNative, _CryptDart>('CryptProtectData');
  static final _unprotect = _crypt32.lookupFunction<_CryptNative, _CryptDart>('CryptUnprotectData');
  static final _localFree = _kernel32
      .lookupFunction<Pointer<Void> Function(Pointer<Void>), Pointer<Void> Function(Pointer<Void>)>(
          'LocalFree');
  static const _uiForbidden = 0x1;

  static Uint8List protect(List<int> data) => _run(_protect, data);
  static Uint8List unprotect(List<int> data) => _run(_unprotect, data);

  static Uint8List _run(_CryptDart fn, List<int> data) {
    final input = calloc<_Blob>();
    final output = calloc<_Blob>();
    final buf = calloc<Uint8>(data.isEmpty ? 1 : data.length);
    try {
      buf.asTypedList(data.length).setAll(0, data);
      input.ref
        ..cbData = data.length
        ..pbData = buf;
      final ok = fn(input, nullptr, nullptr, nullptr, nullptr, _uiForbidden, output);
      if (ok == 0) throw const OSError('DPAPI call failed');
      final result = Uint8List.fromList(output.ref.pbData.asTypedList(output.ref.cbData));
      _localFree(output.ref.pbData.cast());
      return result;
    } finally {
      calloc.free(buf);
      calloc.free(input);
      calloc.free(output);
    }
  }
}

/// Key store for the portable Windows build: a JSON file next to the data,
/// each value encrypted with DPAPI for the current Windows user.
///
/// On another PC / user the values can't be decrypted; they are treated as
/// missing, so the device gets a new identity and has to be paired again.
/// Notes are not affected.
class DpapiFileKeyStore implements KeyStore {
  final File file;
  Map<String, String>? _cache;

  DpapiFileKeyStore(this.file);

  Map<String, String> _load() {
    if (_cache != null) return _cache!;
    var m = <String, String>{};
    try {
      if (file.existsSync()) {
        m = (jsonDecode(file.readAsStringSync()) as Map).cast<String, String>();
      }
    } catch (_) {}
    return _cache = m;
  }

  void _save() {
    final tmp = File('${file.path}.tmp');
    tmp.writeAsStringSync(jsonEncode(_cache), flush: true);
    tmp.renameSync(file.path);
  }

  @override
  Future<Uint8List?> read(String key) async {
    final v = _load()[key];
    if (v == null) return null;
    try {
      return Dpapi.unprotect(base64Decode(v));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String key, List<int> value) async {
    _load()[key] = base64Encode(Dpapi.protect(value));
    _save();
  }

  @override
  Future<void> delete(String key) async {
    if (_load().remove(key) != null) _save();
  }
}
