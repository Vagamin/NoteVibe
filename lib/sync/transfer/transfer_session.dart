import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../crypto/keys.dart';
import '../crypto/secure_channel.dart';
import '../transport/frame_channel.dart';
import '../discovery/lan_discovery.dart';

/// A separate QR namespace prevents confusing a transfer with permanent pairing.
class TransferQr {
  final String id;
  final Uint8List key;
  final Uint8List token;
  final List<String> addresses;
  final int port;
  final DateTime expiresAt;
  TransferQr({required this.id, required this.key, required this.token,
    required this.addresses, required this.port, required this.expiresAt});

  String encode() => Uri(scheme: 'notehub', host: 'transfer', queryParameters: {
    'v': '1', 'id': id, 'k': base64UrlEncode(key), 't': base64UrlEncode(token),
    'a': addresses.join(','), 'p': '$port', 'e': '${expiresAt.millisecondsSinceEpoch}',
  }).toString();

  static TransferQr? tryParse(String text) {
    try {
      if (text.length > 4096) return null;
      final uri = Uri.parse(text.trim());
      if (uri.scheme != 'notehub' || uri.host != 'transfer') return null;
      final q = uri.queryParameters;
      if (q['v'] != '1') return null;
      final key = base64Url.decode(q['k']!);
      final token = base64Url.decode(q['t']!);
      final addresses = q['a']!.split(',');
      final port = int.parse(q['p']!);
      final expires = DateTime.fromMillisecondsSinceEpoch(int.parse(q['e']!));
      final now = DateTime.now();
      if (key.length != 32 || token.length != 32 || q['id']!.isEmpty || q['id']!.length > 128 ||
          port < 1 || port > 65535 || addresses.isEmpty || addresses.length > 8 ||
          addresses.any((a) => !_lanAddress(a)) || !expires.isAfter(now) ||
          expires.isAfter(now.add(const Duration(minutes: 6)))) {
        return null;
      }
      return TransferQr(id: q['id']!, key: key, token: token, addresses: addresses,
        port: port, expiresAt: expires);
    } catch (_) { return null; }
  }
}

bool _lanAddress(String text) {
  final ip = InternetAddress.tryParse(text);
  if (ip == null || ip.type != InternetAddressType.IPv4) return false;
  final b = ip.rawAddress;
  return b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
    (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254) || b[0] == 127;
}

class _TransferPolicy extends HandshakePolicy {
  final Uint8List token;
  final String code;
  _TransferPolicy(this.token, this.code);
  @override
  Future<Uint8List?> peerKey(String deviceId) async => null;
  @override
  List<int>? pairingSecret(HandshakeMode mode) => switch (mode) {
    HandshakeMode.pairQr => token,
    HandshakeMode.pairCode => utf8.encode(code),
    _ => null,
  };
}

/// Ephemeral listener: no NoteStore, PeerKeys or persistent device identity.
/// The QR is consumed only after an authenticated handshake succeeds.
class TransferSession {
  final ServerSocket _server;
  final DeviceIdentity _identity;
  final TransferQr qr;
  final String code;
  LanDiscovery? _discovery;
  final _ready = Completer<SecureChannel>();
  SocketFrameChannel? _pending;
  Timer? _timer;
  bool _closed = false;
  bool _used = false;
  int _failures = 0;
  TransferSession._(this._server, this._identity, this.qr, this.code) {
    // Attach a handler even if the screen has not started awaiting yet.
    unawaited(_ready.future.then<void>((_) {}, onError: (Object _) {}));
    _server.listen(_accept, onError: (Object _) { unawaited(close()); });
    _timer = Timer(qr.expiresAt.difference(DateTime.now()), () { unawaited(close()); });
  }

  Future<SecureChannel> get connected => _ready.future;

  static Future<TransferSession> create({required List<String> addresses,
      Duration lifetime = const Duration(minutes: 5)}) async {
    if (addresses.isEmpty || addresses.length > 8 || addresses.any((a) => !_lanAddress(a)) ||
        lifetime <= Duration.zero || lifetime > const Duration(minutes: 5)) {
      throw ArgumentError('Invalid LAN transfer offer');
    }
    final random = Random.secure();
    Uint8List bytes() => Uint8List.fromList(List.generate(32, (_) => random.nextInt(256)));
    final identity = await DeviceIdentity.fromSeed(base64UrlEncode(bytes()), 'Разовая передача', bytes());
    final server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    final qr = TransferQr(id: identity.deviceId, key: identity.publicKey, token: bytes(),
      addresses: List.unmodifiable(addresses), port: server.port, expiresAt: DateTime.now().add(lifetime));
    return TransferSession._(server, identity, qr, random.nextInt(1000000).toString().padLeft(6, '0'));
  }

  static const discoveryPort = 47801;

  Future<void> announce(String name) async {
    if (_closed || _used || _discovery != null) return;
    final discovery = LanDiscovery(deviceId: qr.id, name: name,
      fingerprint: base64UrlEncode(qr.key), tcpPort: () => qr.port, udpPort: discoveryPort);
    _discovery = discovery;
    try { await discovery.start(); }
    catch (_) { discovery.dispose(); _discovery = null; rethrow; }
  }

  Future<void> _accept(Socket socket) async {
    if (_closed || _used || _pending != null || DateTime.now().isAfter(qr.expiresAt)) {
      socket.destroy();
      return;
    }
    final channel = SocketFrameChannel(socket);
    _pending = channel;
    try {
      final secure = await respondHandshake(channel, _identity, _TransferPolicy(qr.token, code));
      if (_closed || DateTime.now().isAfter(qr.expiresAt)) {
        await secure.close();
        return;
      }
      _used = true;
      _discovery?.dispose();
      _discovery = null;
      _timer?.cancel();
      await _server.close();
      _ready.complete(secure);
    } catch (_) {
      if (++_failures >= 3) await close();
    } finally {
      _pending = null;
    }
  }

  /// Closes a pending offer, not the successfully handed-off secure channel.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _discovery?.dispose();
    _discovery = null;
    _timer?.cancel();
    await _server.close();
    if (!_used) await _pending?.close();
    if (!_ready.isCompleted) _ready.completeError(TransportException('Передача отменена или QR-код истёк'));
  }

  static Future<SecureChannel> connect(String encoded) async {
    final qr = TransferQr.tryParse(encoded);
    if (qr == null) throw const FormatException('Недействительный или истёкший QR-код передачи');
    final identity = await DeviceIdentity.loadOrCreate(MemoryKeyStore(),
      base64UrlEncode(List.generate(32, (_) => Random.secure().nextInt(256))), 'Разовая передача');
    for (final address in qr.addresses) {
      if (!qr.expiresAt.isAfter(DateTime.now())) break;
      try {
        final channel = await SocketFrameChannel.connect(address, qr.port);
        return await initiateHandshake(channel, identity, mode: HandshakeMode.pairQr,
          expectedId: qr.id, expectedKey: qr.key, secret: qr.token);
      } on HandshakeException { rethrow; }
      on TransportException { continue; }
    }
    throw TransportException('Не удалось подключиться. Проверьте общую Wi-Fi сеть');
  }

  static Future<SecureChannel> connectCode(DiscoveredDevice device, String code) async {
    if (!RegExp(r'^\d{6}$').hasMatch(code) || !_lanAddress(device.address) ||
        device.port < 1 || device.port > 65535 || device.deviceId.length > 128 ||
        DateTime.now().difference(device.seenAt) > const Duration(seconds: 15)) {
      throw const FormatException('Выберите отправителя и введите шесть цифр');
    }
    final key = base64Url.decode(device.fingerprint);
    if (key.length != 32) throw const FormatException('Некорректное объявление передачи');
    final identity = await DeviceIdentity.loadOrCreate(MemoryKeyStore(),
      base64UrlEncode(List.generate(32, (_) => Random.secure().nextInt(256))), 'Разовая передача');
    final channel = await SocketFrameChannel.connect(device.address, device.port);
    return initiateHandshake(channel, identity, mode: HandshakeMode.pairCode,
      expectedId: device.deviceId, expectedKey: key, secret: utf8.encode(code));
  }
}
