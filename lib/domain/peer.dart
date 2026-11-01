/// A device this device has been paired with.
class Peer {
  final String deviceId;
  final String name;

  /// Static X25519 public key of the peer (stored in OS secure storage).
  final List<int> publicKey;
  final DateTime pairedAt;
  final DateTime? lastSyncAt;
  final String? lastAddress;
  final int? lastPort;

  /// Highest change_log sequence of the peer we have durably applied.
  final int recvCursor;

  const Peer({
    required this.deviceId,
    required this.name,
    required this.publicKey,
    required this.pairedAt,
    this.lastSyncAt,
    this.lastAddress,
    this.lastPort,
    this.recvCursor = 0,
  });
}
