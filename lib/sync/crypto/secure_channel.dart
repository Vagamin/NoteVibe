import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../transport/frame_channel.dart';
import 'keys.dart';

const protocolVersion = 1;

enum HandshakeMode { sync, pairQr, pairCode }

class HandshakeException implements Exception {
  final String code;
  final String message;
  HandshakeException(this.code, this.message);
  @override
  String toString() => 'HandshakeException($code): $message';
}

/// Error codes exchanged in plaintext before the session key is established.
abstract class HsError {
  static const unknownPeer = 'unknown_peer';
  static const noPairing = 'no_pairing';
  static const badKey = 'bad_key';
  static const badCode = 'bad_code';
  static const busy = 'busy';
  static const version = 'version';
}

/// Parameters for hardening the 6-digit pairing code against offline
/// brute force by an active attacker (see docs/PROTOCOL.md).
class CodeKdf {
  final int memoryKb;
  final int iterations;
  const CodeKdf({this.memoryKb = 8192, this.iterations = 2});
  static const fast = CodeKdf(memoryKb: 64, iterations: 1);

  Future<List<int>> derive(String code, List<int> salt) async {
    final a = Argon2id(parallelism: 1, memory: memoryKb, iterations: iterations, hashLength: 32);
    final k = await a.deriveKey(secretKey: SecretKey(utf8.encode(code)), nonce: salt);
    return k.extractBytes();
  }
}

/// Information about the remote side, available after the handshake.
class RemoteInfo {
  final String deviceId;
  final String name;
  final Uint8List staticKey;
  final HandshakeMode mode;
  RemoteInfo(this.deviceId, this.name, this.staticKey, this.mode);
}

/// Encrypted, authenticated message channel (ChaCha20-Poly1305, per-direction
/// keys, counter nonces). Any tampering, replay or reordering fails decryption.
class SecureChannel {
  final FrameChannel _inner;
  final SecretKey _sendKey;
  final SecretKey _recvKey;
  final RemoteInfo remote;
  int _sendCounter = 0;
  int _recvCounter = 0;
  static final _aead = Chacha20.poly1305Aead();

  SecureChannel._(this._inner, this._sendKey, this._recvKey, this.remote);

  static List<int> _nonce(int counter) {
    final b = ByteData(12)..setUint64(4, counter);
    return b.buffer.asUint8List();
  }

  Future<void> send(Map<String, dynamic> msg) async {
    final clear = utf8.encode(jsonEncode(msg));
    final box = await _aead.encrypt(clear, secretKey: _sendKey, nonce: _nonce(_sendCounter++));
    await _inner.send(Uint8List.fromList(box.cipherText + box.mac.bytes));
  }

  Future<Map<String, dynamic>> receive({Duration timeout = const Duration(seconds: 30)}) async {
    final frame = await _inner.receive(timeout: timeout);
    if (frame.length < 16) throw TransportException('short frame');
    final box = SecretBox(
      frame.sublist(0, frame.length - 16),
      nonce: _nonce(_recvCounter++),
      mac: Mac(frame.sublist(frame.length - 16)),
    );
    final List<int> clear;
    try {
      clear = await _aead.decrypt(box, secretKey: _recvKey);
    } on SecretBoxAuthenticationError {
      throw TransportException('message authentication failed');
    }
    return jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
  }

  Future<void> close() => _inner.close();
  String get remoteAddress => _inner.remoteAddress;
}

final _x25519 = X25519();
final _sha256 = Sha256();

Future<List<int>> _dh(KeyPair kp, List<int> pub) async {
  final s = await _x25519.sharedSecretKey(
      keyPair: kp, remotePublicKey: SimplePublicKey(pub, type: KeyPairType.x25519));
  return s.extractBytes();
}

Uint8List _b64(Object? v) {
  if (v is! String) throw HandshakeException('proto', 'missing key');
  final b = base64Decode(v);
  if (b.length != 32) throw HandshakeException('proto', 'bad key length');
  return b;
}

Future<void> _sendPlain(FrameChannel ch, Map<String, dynamic> m) =>
    ch.send(Uint8List.fromList(utf8.encode(jsonEncode(m))));

Future<(SecretKey, SecretKey)> _deriveKeys(
    List<int> ikm, List<int> transcript, List<int> psk) async {
  final th = (await _sha256.hash(transcript)).bytes;
  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 64);
  final okm = await (await hkdf.deriveKey(
    secretKey: SecretKey(ikm),
    nonce: th,
    info: [...utf8.encode('notevibe-v1'), ...psk],
  ))
      .extractBytes();
  return (SecretKey(okm.sublist(0, 32)), SecretKey(okm.sublist(32, 64)));
}

/// Initiator side of the handshake.
///
/// * sync: [expectedKey] is the stored static key of the peer.
/// * pairQr: [expectedKey] comes from the QR code, [secret] is the QR token.
/// * pairCode: [secret] is the 6-digit code typed by the user.
///
/// On failure the underlying channel is closed.
Future<SecureChannel> initiateHandshake(
  FrameChannel ch,
  DeviceIdentity me, {
  required HandshakeMode mode,
  String? expectedId,
  List<int>? expectedKey,
  List<int>? secret,
  CodeKdf kdf = const CodeKdf(),
}) async {
  try {
    return await _initiate(ch, me,
        mode: mode, expectedId: expectedId, expectedKey: expectedKey, secret: secret, kdf: kdf);
  } catch (_) {
    await ch.close();
    rethrow;
  }
}

Future<SecureChannel> _initiate(
  FrameChannel ch,
  DeviceIdentity me, {
  required HandshakeMode mode,
  String? expectedId,
  List<int>? expectedKey,
  List<int>? secret,
  required CodeKdf kdf,
}) async {
  final eph = await _x25519.newKeyPair();
  final ephPub = (await eph.extractPublicKey()).bytes;
  final m1 = {
    'v': protocolVersion,
    't': 'hello',
    'mode': mode.name,
    'id': me.deviceId,
    'name': me.name,
    'e': base64Encode(ephPub),
    's': base64Encode(me.publicKey),
  };
  final m1b = utf8.encode(jsonEncode(m1));
  await ch.send(Uint8List.fromList(m1b));

  final f2 = await ch.receive(timeout: const Duration(seconds: 15));
  final Map<String, dynamic> m2;
  try {
    m2 = jsonDecode(utf8.decode(f2)) as Map<String, dynamic>;
  } catch (_) {
    throw HandshakeException('proto', 'malformed handshake');
  }
  if (m2['t'] == 'error') {
    throw HandshakeException(m2['code'] as String? ?? 'error', m2['msg'] as String? ?? '');
  }
  final rId = m2['id'] as String;
  final rE = _b64(m2['e']);
  final rS = _b64(m2['s']);
  if (expectedId != null && rId != expectedId) {
    throw HandshakeException(HsError.badKey, 'unexpected device');
  }
  if (expectedKey != null && !_eq(expectedKey, rS)) {
    throw HandshakeException(HsError.badKey, 'device key mismatch');
  }

  final ikm = [
    ...await _dh(eph, rE),
    ...await _dh(me.keyPair, rE),
    ...await _dh(eph, rS),
  ];
  final transcript = [...m1b, ...f2];
  final psk = await _psk(mode, secret, transcript, kdf);
  final (kI2R, kR2I) = await _deriveKeys(ikm, transcript, psk);
  final sc = SecureChannel._(ch, kI2R, kR2I,
      RemoteInfo(rId, m2['name'] as String? ?? rId, rS, mode));
  await sc.send({'t': 'confirm'});
  try {
    final c = await sc.receive(timeout: const Duration(seconds: 15));
    if (c['t'] != 'confirm') throw HandshakeException('proto', 'expected confirm');
  } on TransportException {
    throw HandshakeException(
        mode == HandshakeMode.pairCode ? HsError.badCode : HsError.badKey, 'key confirmation failed');
  }
  return sc;
}

/// Decides whether to accept an incoming handshake.
abstract class HandshakePolicy {
  /// For sync mode: stored key of [deviceId], or null if not paired.
  Future<Uint8List?> peerKey(String deviceId);

  /// For pairing modes: secret to use, or null if no pairing offer is active.
  /// For pairQr returns the token, for pairCode the code bytes.
  List<int>? pairingSecret(HandshakeMode mode);

  /// Called when key confirmation failed in pairCode mode (wrong code).
  void onPairingFailure() {}
}

/// Responder side of the handshake. On failure the channel is closed.
Future<SecureChannel> respondHandshake(
  FrameChannel ch,
  DeviceIdentity me,
  HandshakePolicy policy, {
  CodeKdf kdf = const CodeKdf(),
}) async {
  try {
    return await _respond(ch, me, policy, kdf);
  } catch (_) {
    await ch.close();
    rethrow;
  }
}

Future<SecureChannel> _respond(
  FrameChannel ch,
  DeviceIdentity me,
  HandshakePolicy policy,
  CodeKdf kdf,
) async {
  final f1 = await ch.receive(timeout: const Duration(seconds: 15));
  final Map<String, dynamic> m1;
  try {
    m1 = jsonDecode(utf8.decode(f1)) as Map<String, dynamic>;
  } catch (_) {
    throw HandshakeException('proto', 'malformed handshake');
  }
  Future<Never> reject(String code, String msg) async {
    await _sendPlain(ch, {'t': 'error', 'code': code, 'msg': msg}).catchError((_) {});
    throw HandshakeException(code, msg);
  }

  if (m1['v'] != protocolVersion) await reject(HsError.version, 'unsupported protocol');
  final mode = HandshakeMode.values.firstWhere((m) => m.name == m1['mode'],
      orElse: () => throw HandshakeException('proto', 'bad mode'));
  final iId = m1['id'] as String;
  final iE = _b64(m1['e']);
  final iS = _b64(m1['s']);

  List<int>? secret;
  if (mode == HandshakeMode.sync) {
    final known = await policy.peerKey(iId);
    if (known == null) await reject(HsError.unknownPeer, 'device is not paired');
    if (!_eq(known, iS)) await reject(HsError.badKey, 'device key mismatch');
  } else {
    secret = policy.pairingSecret(mode);
    if (secret == null) await reject(HsError.noPairing, 'pairing is not active');
  }

  final eph = await _x25519.newKeyPair();
  final m2 = {
    'v': protocolVersion,
    't': 'hello',
    'id': me.deviceId,
    'name': me.name,
    'e': base64Encode((await eph.extractPublicKey()).bytes),
    's': base64Encode(me.publicKey),
  };
  final m2b = utf8.encode(jsonEncode(m2));
  await ch.send(Uint8List.fromList(m2b));

  final ikm = [
    ...await _dh(eph, iE),
    ...await _dh(eph, iS),
    ...await _dh(me.keyPair, iE),
  ];
  final transcript = [...f1, ...m2b];
  final psk = await _psk(mode, secret, transcript, kdf);
  final (kI2R, kR2I) = await _deriveKeys(ikm, transcript, psk);
  final sc = SecureChannel._(ch, kR2I, kI2R,
      RemoteInfo(iId, m1['name'] as String? ?? iId, iS, mode));
  try {
    final c = await sc.receive(timeout: const Duration(seconds: 30));
    if (c['t'] != 'confirm') throw HandshakeException('proto', 'expected confirm');
  } on TransportException {
    if (mode == HandshakeMode.pairCode) policy.onPairingFailure();
    throw HandshakeException(
        mode == HandshakeMode.pairCode ? HsError.badCode : HsError.badKey, 'key confirmation failed');
  }
  await sc.send({'t': 'confirm'});
  return sc;
}

Future<List<int>> _psk(
    HandshakeMode mode, List<int>? secret, List<int> transcript, CodeKdf kdf) async {
  switch (mode) {
    case HandshakeMode.sync:
      return const [];
    case HandshakeMode.pairQr:
      return secret!;
    case HandshakeMode.pairCode:
      final salt = (await _sha256.hash(transcript)).bytes;
      return kdf.derive(utf8.decode(secret!), salt);
  }
}

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var d = 0;
  for (var i = 0; i < a.length; i++) {
    d |= a[i] ^ b[i];
  }
  return d == 0;
}
