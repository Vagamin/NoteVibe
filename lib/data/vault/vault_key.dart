import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Password wraps a random data key; changing the password need not rewrite
/// every attachment. No password, unwrapped key or password hint is persisted.
class VaultKey {
  static final _cipher = AesGcm.with256bits();
  static const _memory = 65536;
  static const _iterations = 3;

  static Uint8List randomBytes(int count) {
    final random = Random.secure();
    return Uint8List.fromList(List.generate(count, (_) => random.nextInt(256)));
  }

  static Future<SecretKey> create() async => SecretKey(randomBytes(32));

  static Future<SecretKey> _derive(String password, List<int> salt) => Argon2id(
    parallelism: 1, memory: _memory, iterations: _iterations, hashLength: 32,
  ).deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);

  static Future<String> wrap(SecretKey key, String password) async {
    if (password.isEmpty || password.length > 1024) {
      throw ArgumentError('Пароль должен содержать от 1 до 1024 символов');
    }
    final salt = randomBytes(16);
    final nonce = randomBytes(12);
    final bytes = await key.extractBytes();
    if (bytes.length != 32) throw ArgumentError('Invalid data key');
    final box = await _cipher.encrypt(bytes, secretKey: await _derive(password, salt),
      nonce: nonce, aad: utf8.encode('notehub-vault-key-v1'));
    return jsonEncode({'v': 1, 'kdf': 'argon2id-64m-3', 'salt': base64Encode(salt),
      'nonce': base64Encode(nonce), 'key': base64Encode(box.cipherText + box.mac.bytes)});
  }

  static Future<SecretKey> unwrap(String encoded, String password) async {
    if (encoded.length > 2048 || password.isEmpty || password.length > 1024) {
      throw const FormatException('Некорректный заголовок хранилища или пароль');
    }
    final m = jsonDecode(encoded);
    if (m is! Map || m['v'] != 1 || m['kdf'] != 'argon2id-64m-3') {
      throw const FormatException('Неподдерживаемый формат хранилища');
    }
    final salt = base64Decode(m['salt'] as String);
    final nonce = base64Decode(m['nonce'] as String);
    final wrapped = base64Decode(m['key'] as String);
    if (salt.length != 16 || nonce.length != 12 || wrapped.length != 48) {
      throw const FormatException('Повреждён заголовок хранилища');
    }
    final clear = await _cipher.decrypt(SecretBox(wrapped.sublist(0, 32),
      nonce: nonce, mac: Mac(wrapped.sublist(32))),
      secretKey: await _derive(password, salt), aad: utf8.encode('notehub-vault-key-v1'));
    return SecretKey(clear);
  }
}
