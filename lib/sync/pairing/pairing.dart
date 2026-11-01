import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../crypto/secure_channel.dart';

/// Payload encoded in the pairing QR code.
///
/// `notevibe://pair?v=1&id=<deviceId>&n=<name>&k=<pubkey b64url>&t=<token b64url>&a=<ip,ip>&p=<port>`
class PairingQr {
  final String deviceId;
  final String name;
  final Uint8List publicKey;
  final Uint8List token;
  final List<String> addresses;
  final int port;

  PairingQr({
    required this.deviceId,
    required this.name,
    required this.publicKey,
    required this.token,
    required this.addresses,
    required this.port,
  });

  String encode() => Uri(
        scheme: 'notevibe',
        host: 'pair',
        queryParameters: {
          'v': '1',
          'id': deviceId,
          'n': name,
          'k': base64Url.encode(publicKey),
          't': base64Url.encode(token),
          'a': addresses.join(','),
          'p': '$port',
        },
      ).toString();

  static PairingQr? tryParse(String text) {
    try {
      final u = Uri.parse(text.trim());
      if (u.scheme != 'notevibe' || u.host != 'pair') return null;
      final q = u.queryParameters;
      if (q['v'] != '1') return null;
      final key = base64Url.decode(q['k']!);
      final token = base64Url.decode(q['t']!);
      if (key.length != 32 || token.length < 16) return null;
      return PairingQr(
        deviceId: q['id']!,
        name: q['n'] ?? q['id']!,
        publicKey: key,
        token: token,
        addresses: q['a']!.split(',').where((s) => s.isNotEmpty).toList(),
        port: int.parse(q['p']!),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Active pairing offer shown on one device (QR + 6-digit code).
///
/// Offers expire after [lifetime], are single use, and the code is revoked
/// after [maxAttempts] failed attempts.
class PairingOffer {
  final Uint8List token;
  final String code;
  final DateTime expiresAt;
  int failedAttempts = 0;
  bool used = false;
  static const maxAttempts = 3;

  PairingOffer._(this.token, this.code, this.expiresAt);

  factory PairingOffer.create({Duration lifetime = const Duration(minutes: 2), Random? rnd}) {
    final r = rnd ?? Random.secure();
    final token = Uint8List.fromList(List.generate(16, (_) => r.nextInt(256)));
    final code = List.generate(6, (_) => r.nextInt(10)).join();
    return PairingOffer._(token, code, DateTime.now().add(lifetime));
  }

  bool get expired => DateTime.now().isAfter(expiresAt);
  bool get codeRevoked => failedAttempts >= maxAttempts;
  bool get active => !used && !expired;

  List<int>? secretFor(HandshakeMode mode) {
    if (!active) return null;
    return switch (mode) {
      HandshakeMode.pairQr => token,
      HandshakeMode.pairCode => codeRevoked ? null : utf8.encode(code),
      HandshakeMode.sync => null,
    };
  }
}
