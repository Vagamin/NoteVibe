import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Abstraction over OS-provided secure storage (Android Keystore,
/// Windows DPAPI, macOS Keychain, Linux libsecret).
abstract class KeyStore {
  Future<Uint8List?> read(String key);
  Future<void> write(String key, List<int> value);
  Future<void> delete(String key);
}

class SecureKeyStore implements KeyStore {
  final FlutterSecureStorage _s;
  SecureKeyStore([FlutterSecureStorage? s]) : _s = s ?? const FlutterSecureStorage();

  @override
  Future<Uint8List?> read(String key) async {
    final v = await _s.read(key: key);
    return v == null ? null : base64Decode(v);
  }

  @override
  Future<void> write(String key, List<int> value) => _s.write(key: key, value: base64Encode(value));

  @override
  Future<void> delete(String key) => _s.delete(key: key);
}

class MemoryKeyStore implements KeyStore {
  final _m = <String, Uint8List>{};
  @override
  Future<Uint8List?> read(String key) async => _m[key];
  @override
  Future<void> write(String key, List<int> value) async => _m[key] = Uint8List.fromList(value);
  @override
  Future<void> delete(String key) async => _m.remove(key);
}

/// Long-term identity of this device: id + static X25519 key pair.
class DeviceIdentity {
  final String deviceId;
  final String name;
  final SimpleKeyPair keyPair;
  final Uint8List publicKey;

  DeviceIdentity._(this.deviceId, this.name, this.keyPair, this.publicKey);

  static final _x = X25519();

  static Future<DeviceIdentity> fromSeed(String deviceId, String name, List<int> seed) async {
    final kp = await _x.newKeyPairFromSeed(seed);
    final pub = await kp.extractPublicKey();
    return DeviceIdentity._(deviceId, name, kp, Uint8List.fromList(pub.bytes));
  }

  /// Loads the identity key from [store] or creates a new one.
  static Future<DeviceIdentity> loadOrCreate(KeyStore store, String deviceId, String name) async {
    var seed = await store.read('identity_x25519');
    if (seed == null) {
      seed = Uint8List.fromList(SecretKeyData.random(length: 32).bytes);
      await store.write('identity_x25519', seed);
    }
    return fromSeed(deviceId, name, seed);
  }

  DeviceIdentity withName(String newName) => DeviceIdentity._(deviceId, newName, keyPair, publicKey);

  String get fingerprint => fingerprintOf(publicKey);
}

/// Short human-readable key fingerprint (first 8 bytes of SHA-256, hex).
String fingerprintOf(List<int> publicKey) {
  final h = _sha256Sync(publicKey);
  return h.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

List<int> _sha256Sync(List<int> data) => const DartSha256().hashSync(data).bytes;

/// Storage of trusted peer keys inside the OS secure storage.
class PeerKeys {
  final KeyStore store;
  PeerKeys(this.store);
  Future<Uint8List?> get(String deviceId) => store.read('peer_$deviceId');
  Future<void> put(String deviceId, List<int> pub) => store.write('peer_$deviceId', pub);
  Future<void> remove(String deviceId) => store.delete('peer_$deviceId');
}
