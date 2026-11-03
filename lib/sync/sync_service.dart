import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../data/attachment_storage.dart';
import '../data/note_store.dart';
import '../domain/attachment.dart';
import '../domain/peer.dart';
import 'crypto/keys.dart';
import 'crypto/secure_channel.dart';
import 'discovery/lan_discovery.dart';
import 'engine/file_transfer.dart';
import 'engine/sync_engine.dart';
import 'pairing/pairing.dart';
import 'transport/frame_channel.dart';

enum SyncState { synced, syncing, offline, conflict }

class FileTransfer {
  final Attachment attachment;
  final int received;
  final String status;
  const FileTransfer(this.attachment, this.received, this.status);
  bool get active => status == 'Загрузка' || status == 'Проверка файла';
}

class SyncStatus {
  final SyncState state;
  final bool autoSync;
  final int reachablePeers;
  final int pairedPeers;
  final DateTime? lastSync;
  final String? lastError;

  const SyncStatus({
    required this.state,
    required this.autoSync,
    this.reachablePeers = 0,
    this.pairedPeers = 0,
    this.lastSync,
    this.lastError,
  });

  String get label => switch (state) {
        SyncState.synced => 'Синхронизировано',
        SyncState.syncing => 'Синхронизация',
        SyncState.offline => 'Нет подключения',
        SyncState.conflict => 'Конфликт',
      };
}

class PairingException implements Exception {
  final String message;
  PairingException(this.message);
  @override
  String toString() => message;
}

/// Orchestrates LAN sync: TCP server, discovery, pairing and automatic
/// sync sessions with retries. Pure Dart, so it is testable without Flutter.
class SyncService {
  final transfers = <String, FileTransfer>{};
  final _transferEvents = StreamController<void>.broadcast();
  Stream<void> get transferEvents => _transferEvents.stream;
  final _downloads = <String, Future<void>>{};

  void _transfer(Attachment a, int received, String status) {
    transfers[a.sha256] = FileTransfer(a, received, status);
    if (transfers.length > 50) {
      final finished = transfers.keys.where((key) => !transfers[key]!.active && key != a.sha256).toList();
      if (finished.isNotEmpty) transfers.remove(finished.first);
    }
    _transferEvents.add(null);
  }
  static const preferredPort = 47801;

  final NoteStore store;
  final PeerKeys peerKeys;
  DeviceIdentity identity;
  final bool enableDiscovery;
  final CodeKdf kdf;
  final Duration periodic;
  final Duration debounce;
  final AttachmentStorage? files;

  ServerSocket? _server;
  LanDiscovery? _discovery;
  PairingOffer? _offer;
  final _offerEvents = StreamController<String>.broadcast();

  final _active = <String>{};
  int _incoming = 0;
  final _manualAddr = <String, (String, int)>{};
  final _backoffUntil = <String, DateTime>{};
  final _failures = <String, int>{};
  bool _dirty = true;
  String? _lastError;
  DateTime? _lastSync;
  Timer? _debounceTimer;
  Timer? _periodicTimer;
  StreamSubscription<void>? _storeSub;
  StreamSubscription<List<DiscoveredDevice>>? _discSub;
  final _statusCtl = StreamController<SyncStatus>.broadcast();
  final _discoveredCtl = StreamController<List<DiscoveredDevice>>.broadcast();
  bool _started = false;
  int _suppressDirty = 0;

  SyncService({
    required this.store,
    required this.peerKeys,
    required this.identity,
    this.enableDiscovery = true,
    this.kdf = const CodeKdf(),
    this.periodic = const Duration(seconds: 30),
    this.debounce = const Duration(seconds: 2),
    this.files,
  });

  // ------------------------------------------------------------ lifecycle

  bool get autoSync => store.getSetting('auto_sync') != 'false';

  set autoSync(bool v) {
    store.setSetting('auto_sync', v ? 'true' : 'false');
    if (v) {
      _scheduleSync(immediate: true);
    } else {
      _debounceTimer?.cancel();
    }
    _emitStatus();
  }

  int get port => _server?.port ?? 0;

  Stream<SyncStatus> get status => _statusCtl.stream;
  SyncStatus get currentStatus => _computeStatus();

  Stream<List<DiscoveredDevice>> get discovered => _discoveredCtl.stream;
  List<DiscoveredDevice> get currentDiscovered => _discovery?.current ?? const [];

  /// Fires with the remote device name when someone paired via our offer.
  Stream<String> get pairedEvents => _offerEvents.stream;

  Future<void> start({int? port}) async {
    if (_started) return;
    _started = true;
    _server = await _bind(port);
    _server!.listen(_onIncoming, onError: (_) {});
    _storeSub = store.changes.listen((_) {
      if (_suppressDirty == 0) {
        _dirty = true;
        _scheduleSync();
      }
      _emitStatus();
    });
    if (enableDiscovery) {
      final d = LanDiscovery(
        deviceId: identity.deviceId,
        name: identity.name,
        fingerprint: identity.fingerprint,
        tcpPort: () => this.port,
        unicastTargets: () => [
          for (final p in store.listPeers())
            if (p.lastAddress != null) p.lastAddress!,
        ],
      );
      try {
        await d.start();
        _discovery = d;
        _discSub = d.devices.listen(_onDiscovered);
      } catch (e) {
        _lastError = 'Обнаружение недоступно: $e';
      }
    }
    _periodicTimer = Timer.periodic(periodic, (_) {
      if (autoSync) syncNow(onlyIfNeeded: true);
    });
    _scheduleSync(immediate: true);
    _emitStatus();
  }

  Future<ServerSocket> _bind(int? port) async {
    if (port != null) return ServerSocket.bind(InternetAddress.anyIPv4, port);
    try {
      return await ServerSocket.bind(InternetAddress.anyIPv4, preferredPort);
    } on SocketException {
      return ServerSocket.bind(InternetAddress.anyIPv4, 0);
    }
  }

  Future<void> stop() async {
    _started = false;
    _debounceTimer?.cancel();
    _periodicTimer?.cancel();
    await _storeSub?.cancel();
    await _discSub?.cancel();
    _discovery?.dispose();
    _discovery = null;
    await _server?.close();
    _server = null;
  }

  Future<void> dispose() async {
    await stop();
    while (_active.isNotEmpty || _incoming > 0 || _downloads.isNotEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await _statusCtl.close();
    await _discoveredCtl.close();
    await _offerEvents.close();
    await _transferEvents.close();
  }

  void rename(String name) {
    identity = identity.withName(name);
    _discovery?.name = name;
  }

  /// Called when app returns to foreground / network changes.
  void wakeUp() {
    _discovery?.announce();
    _backoffUntil.clear();
    if (autoSync) _scheduleSync(immediate: true);
  }

  // ------------------------------------------------------------ status

  SyncStatus _computeStatus() {
    final peers = store.listPeers();
    final reachable = peers.where((p) => _addressOf(p) != null && _isReachable(p.deviceId)).length;
    SyncState s;
    if (_active.isNotEmpty || _incoming > 0) {
      s = SyncState.syncing;
    } else if (store.conflictCount > 0) {
      s = SyncState.conflict;
    } else if (peers.isEmpty || reachable == 0 || _lastSync == null || _lastError != null) {
      s = SyncState.offline;
    } else if (_dirty) {
      s = autoSync ? SyncState.syncing : SyncState.offline;
    } else {
      s = SyncState.synced;
    }
    return SyncStatus(
      state: s,
      autoSync: autoSync,
      reachablePeers: reachable,
      pairedPeers: peers.length,
      lastSync: _lastSync,
      lastError: _lastError,
    );
  }

  bool _isReachable(String deviceId) =>
      _isDiscovered(deviceId) || _failures[deviceId] == 0;

  void _emitStatus() {
    if (!_statusCtl.isClosed) _statusCtl.add(_computeStatus());
  }

  // ------------------------------------------------------------ discovery

  void _onDiscovered(List<DiscoveredDevice> list) {
    if (!_discoveredCtl.isClosed) _discoveredCtl.add(list);
    for (final d in list) {
      final p = store.getPeer(d.deviceId);
      if (p == null) continue;
      if (p.lastAddress != d.address || p.lastPort != d.port) {
        store.updatePeerSeen(d.deviceId, address: d.address, port: d.port);
      }
      // Newly seen paired device: sync right away.
      if (autoSync && (_failures[d.deviceId] ?? 1) != 0) {
        _syncPeerSafe(p);
      }
    }
    _emitStatus();
  }

  /// Manually specify the address of a device (when multicast is blocked).
  void addManualAddress(String deviceId, String host, int port) {
    _manualAddr[deviceId] = (host, port);
  }

  (String, int)? _addressOf(Peer p) {
    for (final d in currentDiscovered) {
      if (d.deviceId == p.deviceId) return (d.address, d.port);
    }
    final m = _manualAddr[p.deviceId];
    if (m != null) return m;
    if (p.lastAddress != null) return (p.lastAddress!, p.lastPort ?? preferredPort);
    return null;
  }

  // ------------------------------------------------------------ sync

  void _scheduleSync({bool immediate = false}) {
    if (!autoSync || !_started) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(immediate ? Duration.zero : debounce, () {
      if (autoSync) syncNow();
    });
  }

  /// Syncs with all paired devices that have a known address.
  Future<void> syncNow({bool onlyIfNeeded = false, bool force = false}) async {
    final peers = store.listPeers();
    if (force) _backoffUntil.clear();
    await Future.wait(peers.map((p) async {
      if (onlyIfNeeded && !_dirty && _failures[p.deviceId] == 0 && !_isDiscovered(p.deviceId)) {
        return;
      }
      await _syncPeerSafe(p);
    }));
  }

  bool _isDiscovered(String id) => currentDiscovered.any((d) => d.deviceId == id);

  Future<void> _syncPeerSafe(Peer p) async {
    if (!_started) return;
    if (_active.contains(p.deviceId)) return;
    final until = _backoffUntil[p.deviceId];
    if (until != null && DateTime.now().isBefore(until)) return;
    final addr = _addressOf(p);
    if (addr == null) return;
    _active.add(p.deviceId);
    _emitStatus();
    final logAtStart = store.logSeq;
    try {
      await _syncWith(p, addr.$1, addr.$2);
      _failures[p.deviceId] = 0;
      _backoffUntil.remove(p.deviceId);
      _lastError = null;
      _lastSync = DateTime.now();
      _dirty = store.hasLocalChangeAfter(logAtStart);
      await _autoFetchFiles();
    } catch (e) {
      final n = (_failures[p.deviceId] ?? 0) + 1;
      _failures[p.deviceId] = n;
      final delay = Duration(seconds: [5, 15, 30, 60, 120][n.clamp(1, 5) - 1]);
      _backoffUntil[p.deviceId] = DateTime.now().add(delay);
      _lastError = _describe(e);
    } finally {
      _active.remove(p.deviceId);
      _emitStatus();
      if (_dirty && autoSync && _started) _scheduleSync();
    }
  }

  Future<void> _syncWith(Peer p, String host, int port) async {
    final key = await peerKeys.get(p.deviceId);
    if (key == null) throw PairingException('Ключ устройства не найден, выполните сопряжение заново');
    final ch = await SocketFrameChannel.connect(host, port);
    final sc = await initiateHandshake(ch, identity,
        mode: HandshakeMode.sync, expectedId: p.deviceId, expectedKey: key);
    store.updatePeerSeen(p.deviceId, address: host, port: port);
    await _runEngine(sc, initiator: true);
  }

  static const autoDownloadSetting = 'attachments_auto';

  bool get autoDownloadFiles => store.getSetting(autoDownloadSetting) == 'true';

  /// With automatic download on, fetches files that another device reported
  /// and this device lacks. Failures are ignored; the manual button stays.
  Future<void> _autoFetchFiles() async {
    if (files == null || !autoDownloadFiles) return;
    for (final a in store.allAttachments()) {
      if (!_started) return;
      if (files!.has(a.sha256) || !store.hasRemoteHolder(a.sha256)) continue;
      try {
        await fetchAttachment(a);
      } catch (_) {}
    }
  }

  /// Downloads the bytes of [a] from the first paired device that has them.
  /// Throws if no reachable device has the file.
  Future<void> fetchAttachment(Attachment a) {
    return _downloads.putIfAbsent(a.sha256, () => _trackedFetch(a).whenComplete(() {
      _downloads.remove(a.sha256);
    }));
  }

  Future<void> _trackedFetch(Attachment a) async {
    _transfer(a, 0, 'Загрузка');
    try {
      await _fetchAttachment(a);
      _transfer(a, a.size, 'Загружено');
    } catch (_) {
      _transfer(a, transfers[a.sha256]?.received ?? 0, 'Ошибка загрузки');
      rethrow;
    }
  }

  Future<void> _fetchAttachment(Attachment a) async {
    final storeFiles = files;
    if (storeFiles == null) throw PairingException('Хранилище файлов недоступно');
    Object? lastErr;
    for (final p in store.listPeers()) {
      final addr = _addressOf(p);
      if (addr == null) continue;
      final key = await peerKeys.get(p.deviceId);
      if (key == null) continue;
      try {
        _transfer(a, 0, 'Загрузка');
        final ch = await SocketFrameChannel.connect(addr.$1, addr.$2);
        final sc = await initiateHandshake(ch, identity,
            mode: HandshakeMode.fetch, expectedId: p.deviceId, expectedKey: key);
        try {
          await requestAttachment(sc, a, storeFiles, onProgress: (received) =>
            _transfer(a, received, received == a.size ? 'Проверка файла' : 'Загрузка'));
        } finally {
          await sc.close();
        }
        return;
      } catch (e) {
        lastErr = e;
      }
    }
    if (lastErr == null) throw PairingException('Нет доступных устройств для загрузки');
    throw PairingException('Файл не загружен: ${_describe(lastErr)}');
  }

  Future<SyncStats> _runEngine(SecureChannel sc, {required bool initiator}) async {
    _suppressDirty++;
    try {
      return await SyncEngine(store, heldHashes: _heldOnDisk).run(sc, initiator: initiator);
    } finally {
      _suppressDirty--;
    }
  }

  /// Hashes of attachments whose bytes are actually stored on this device.
  Set<String> _heldOnDisk() {
    final f = files;
    if (f == null) return const {};
    return {for (final h in store.allAttachmentHashes()) if (f.has(h)) h};
  }

  // ------------------------------------------------------------ incoming

  Future<void> _onIncoming(Socket socket) async {
    final ch = SocketFrameChannel(socket);
    final policy = _Policy(this);
    SecureChannel sc;
    try {
      sc = await respondHandshake(ch, identity, policy, kdf: kdf);
    } catch (e) {
      return;
    }
    final remote = sc.remote;
    _incoming++;
    _emitStatus();
    try {
      if (remote.mode == HandshakeMode.fetch) {
        try {
          await serveAttachment(sc, files);
        } finally {
          await sc.close();
        }
      } else if (remote.mode == HandshakeMode.sync) {
        store.updatePeerSeen(remote.deviceId, address: sc.remoteAddress);
        final logAtStart = store.logSeq;
        await _runEngine(sc, initiator: false);
        _failures[remote.deviceId] = 0;
        _backoffUntil.remove(remote.deviceId);
        _lastSync = DateTime.now();
        _lastError = null;
        _dirty = store.hasLocalChangeAfter(logAtStart);
        await _autoFetchFiles();
      } else {
        _offer?.used = true;
        await _trust(remote.deviceId, remote.name, remote.staticKey);
        store.updatePeerSeen(remote.deviceId, address: sc.remoteAddress);
        await sc.send({'t': 'paired', 'port': port});
        try {
          final theirs = await sc.receive();
          store.updatePeerSeen(remote.deviceId,
              address: sc.remoteAddress, port: (theirs['port'] as num?)?.toInt());
        } catch (_) {}
        await sc.close();
        if (!_offerEvents.isClosed) _offerEvents.add(remote.name);
      }
    } catch (e) {
      _lastError = _describe(e);
    } finally {
      _incoming--;
      _emitStatus();
      if (_dirty && autoSync && _started) _scheduleSync();
    }
  }

  // ------------------------------------------------------------ pairing

  PairingOffer? get offer => _offer?.active == true ? _offer : null;

  /// Creates a new pairing offer (QR + 6-digit code), valid 2 minutes.
  Future<(PairingOffer, PairingQr)> createPairingOffer() async {
    _offer = PairingOffer.create();
    final qr = PairingQr(
      deviceId: identity.deviceId,
      name: identity.name,
      publicKey: identity.publicKey,
      token: _offer!.token,
      addresses: await localIPv4Addresses(),
      port: port,
    );
    return (_offer!, qr);
  }

  void cancelPairingOffer() => _offer = null;

  Future<String> pairWithQr(PairingQr qr) async {
    Object? lastErr;
    for (final host in qr.addresses) {
      try {
        final ch = await SocketFrameChannel.connect(host, qr.port, timeout: const Duration(seconds: 3));
        final sc = await initiateHandshake(ch, identity,
            mode: HandshakeMode.pairQr,
            expectedId: qr.deviceId,
            expectedKey: qr.publicKey,
            secret: qr.token,
            kdf: kdf);
        await _finishPairing(sc, host);
        return sc.remote.name;
      } catch (e) {
        lastErr = e;
        if (e is HandshakeException) break;
      }
    }
    throw PairingException(_describe(lastErr ?? 'нет адресов'));
  }

  Future<String> pairWithCode(String host, int port, String code) async {
    try {
      final ch = await SocketFrameChannel.connect(host, port);
      final sc = await initiateHandshake(ch, identity,
          mode: HandshakeMode.pairCode, secret: code.trim().codeUnits, kdf: kdf);
      await _finishPairing(sc, host);
      return sc.remote.name;
    } catch (e) {
      throw PairingException(_describe(e));
    }
  }

  Future<void> _finishPairing(SecureChannel sc, String host) async {
    final m = await sc.receive();
    if (m['t'] != 'paired') throw PairingException('Неожиданный ответ устройства');
    final r = sc.remote;
    await _trust(r.deviceId, r.name, r.staticKey);
    store.updatePeerSeen(r.deviceId, address: host, port: (m['port'] as num?)?.toInt());
    await sc.send({'t': 'paired', 'port': port}).catchError((_) {});
    await sc.close();
    _failures.remove(r.deviceId);
    _scheduleSync(immediate: true);
  }

  Future<void> _trust(String deviceId, String name, Uint8List key) async {
    await peerKeys.put(deviceId, key);
    store.upsertPeer(deviceId: deviceId, name: name, publicKey: key);
  }

  Future<void> unpair(String deviceId) async {
    await peerKeys.remove(deviceId);
    store.removePeer(deviceId);
    _failures.remove(deviceId);
    _manualAddr.remove(deviceId);
    _emitStatus();
  }

  static String _describe(Object e) {
    if (e is HandshakeException) {
      return switch (e.code) {
        HsError.badCode => 'Неверный код сопряжения',
        HsError.noPairing => 'На другом устройстве не открыт экран сопряжения или код устарел',
        HsError.unknownPeer => 'Устройство не сопряжено (возможно, сопряжение удалено на другой стороне)',
        HsError.badKey => 'Ключ устройства не совпадает — возможна подмена',
        HsError.version => 'Несовместимая версия приложения',
        _ => 'Ошибка рукопожатия: ${e.message}',
      };
    }
    if (e is TransportException) return 'Сеть: ${e.message}';
    if (e is SyncProtocolException) return 'Протокол: ${e.message}';
    return e.toString();
  }
}

class _Policy extends HandshakePolicy {
  final SyncService s;
  _Policy(this.s);

  @override
  Future<Uint8List?> peerKey(String deviceId) => s.peerKeys.get(deviceId);

  @override
  List<int>? pairingSecret(HandshakeMode mode) => s._offer?.secretFor(mode);

  @override
  void onPairingFailure() {
    final o = s._offer;
    if (o != null) o.failedAttempts++;
  }
}
