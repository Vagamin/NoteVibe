import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A device announcing itself on the LAN.
class DiscoveredDevice {
  final String deviceId;
  final String name;
  final String address;
  final int port;
  final String fingerprint;
  final DateTime seenAt;

  DiscoveredDevice({
    required this.deviceId,
    required this.name,
    required this.address,
    required this.port,
    required this.fingerprint,
    required this.seenAt,
  });
}

/// LAN discovery over UDP.
///
/// Every [interval] the device sends a small JSON beacon to the multicast
/// group 239.77.88.99:47800 and to the IPv4 broadcast address. Beacons are
/// unauthenticated hints only: the address is later verified by the
/// authenticated handshake, so spoofed beacons cannot leak data.
class LanDiscovery {
  static const multicastGroup = '239.77.88.99';
  static const defaultPort = 47800;

  final String deviceId;
  String name;
  final String fingerprint;
  int Function() tcpPort;
  /// Addresses of known (paired) devices. Beacons are also sent to them
  /// directly, because many Wi‑Fi routers and phones drop multicast/broadcast.
  List<String> Function() unicastTargets;
  final int udpPort;
  final Duration interval;
  final Duration ttl;

  RawDatagramSocket? _socket;
  Timer? _timer;
  final _devices = <String, DiscoveredDevice>{};
  final _controller = StreamController<List<DiscoveredDevice>>.broadcast();

  LanDiscovery({
    required this.deviceId,
    required this.name,
    required this.fingerprint,
    required this.tcpPort,
    List<String> Function()? unicastTargets,
    this.udpPort = defaultPort,
    this.interval = const Duration(seconds: 3),
    this.ttl = const Duration(seconds: 12),
  }) : unicastTargets = unicastTargets ?? (() => const []);

  Stream<List<DiscoveredDevice>> get devices => _controller.stream;
  List<DiscoveredDevice> get current => _devices.values.toList();
  bool get running => _socket != null;

  Future<void> start() async {
    if (_socket != null) return;
    final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, udpPort,
        reuseAddress: true, reusePort: !Platform.isWindows && !Platform.isAndroid);
    s.broadcastEnabled = true;
    s.multicastLoopback = true;
    try {
      s.joinMulticast(InternetAddress(multicastGroup));
    } catch (_) {
      // Some networks / interfaces don't support multicast; broadcast still works.
    }
    s.listen((event) {
      if (event == RawSocketEvent.read) {
        final dg = s.receive();
        if (dg != null) _onDatagram(dg);
      }
    });
    _socket = s;
    _timer = Timer.periodic(interval, (_) => _tick());
    _tick();
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _socket?.close();
    _socket = null;
    _devices.clear();
    _emit();
  }

  void dispose() {
    stop();
    _controller.close();
  }

  /// Sends a beacon immediately (e.g. when the app returns to foreground).
  void announce() => _tick();

  void _tick() {
    final s = _socket;
    if (s == null) return;
    final beacon = _beacon();
    final targets = {multicastGroup, '255.255.255.255'};
    try {
      targets.addAll(unicastTargets());
    } catch (_) {}
    for (final target in targets) {
      try {
        s.send(beacon, InternetAddress(target), udpPort);
      } catch (_) {}
    }
    final now = DateTime.now();
    final before = _devices.length;
    _devices.removeWhere((_, d) => now.difference(d.seenAt) > ttl);
    if (_devices.length != before) _emit();
  }

  List<int> _beacon() => utf8.encode(jsonEncode({
        'nv': 1,
        'id': deviceId,
        'name': name,
        'port': tcpPort(),
        'fp': fingerprint,
      }));

  void _onDatagram(Datagram dg) {
    if (dg.data.length > 1024) return;
    try {
      final m = jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
      if (m['nv'] != 1) return;
      final id = m['id'] as String;
      if (id == deviceId) return;
      final d = DiscoveredDevice(
        deviceId: id,
        name: (m['name'] as String? ?? id),
        address: dg.address.address,
        port: (m['port'] as num).toInt(),
        fingerprint: m['fp'] as String? ?? '',
        seenAt: DateTime.now(),
      );
      final isNew = !_devices.containsKey(id) ||
          _devices[id]!.address != d.address ||
          _devices[id]!.port != d.port;
      _devices[id] = d;
      if (isNew) {
        _emit();
        // Answer directly so the sender learns about us even if our
        // multicast/broadcast beacons don't reach it.
        try {
          _socket?.send(_beacon(), dg.address, udpPort);
        } catch (_) {}
      }
    } catch (_) {
      // Ignore foreign / malformed packets.
    }
  }

  void _emit() {
    if (!_controller.isClosed) _controller.add(current);
  }
}

/// Lists local IPv4 addresses (for showing in QR code / manual connect).
Future<List<String>> localIPv4Addresses() async {
  final result = <String>[];
  try {
    for (final ni in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      for (final a in ni.addresses) {
        if (!a.isLoopback && !a.isLinkLocal) result.add(a.address);
      }
    }
  } catch (_) {}
  // Prefer typical home LAN ranges.
  int rank(String ip) => ip.startsWith('192.168.')
      ? 0
      : ip.startsWith('10.')
          ? 1
          : ip.startsWith('172.')
              ? 2
              : 3;
  result.sort((a, b) => rank(a).compareTo(rank(b)));
  return result;
}
