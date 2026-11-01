import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

/// Exception raised by the transport layer (connection lost, bad frame...).
class TransportException implements Exception {
  final String message;
  TransportException(this.message);
  @override
  String toString() => 'TransportException: $message';
}

/// A bidirectional, message-oriented channel.
abstract class FrameChannel {
  Future<void> send(Uint8List frame);

  /// Waits for the next frame. Throws [TransportException] on close/timeout.
  Future<Uint8List> receive({Duration timeout = const Duration(seconds: 30)});

  Future<void> close();

  String get remoteAddress;
}

/// Shared receive queue logic for channel implementations.
mixin _FrameQueue {
  final _frames = Queue<Uint8List>();
  final _waiters = Queue<Completer<Uint8List>>();
  Object? _error;

  void _push(Uint8List f) {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete(f);
    } else {
      _frames.add(f);
    }
  }

  void _fail(Object error) {
    _error ??= error;
    while (_waiters.isNotEmpty) {
      _waiters.removeFirst().completeError(_error!);
    }
  }

  Future<Uint8List> _next(Duration timeout) {
    if (_frames.isNotEmpty) return Future.value(_frames.removeFirst());
    if (_error != null) return Future.error(_error!);
    final c = Completer<Uint8List>();
    _waiters.add(c);
    return c.future.timeout(timeout, onTimeout: () {
      _waiters.remove(c);
      throw TransportException('timeout');
    });
  }
}

/// Length-prefixed frames over a TCP socket: 4-byte big-endian length + data.
class SocketFrameChannel with _FrameQueue implements FrameChannel {
  static const maxFrame = 16 * 1024 * 1024;
  final Socket _socket;
  final _buf = BytesBuilder(copy: false);
  Uint8List _pending = Uint8List(0);
  late final StreamSubscription<Uint8List> _sub;

  SocketFrameChannel(this._socket) {
    _socket.setOption(SocketOption.tcpNoDelay, true);
    _sub = _socket.listen(_onData,
        onError: (Object e) => _fail(TransportException('socket error: $e')),
        onDone: () => _fail(TransportException('connection closed')),
        cancelOnError: true);
  }

  static Future<SocketFrameChannel> connect(String host, int port,
      {Duration timeout = const Duration(seconds: 5)}) async {
    try {
      final s = await Socket.connect(host, port, timeout: timeout);
      return SocketFrameChannel(s);
    } on SocketException catch (e) {
      throw TransportException('connect failed: ${e.message}');
    }
  }

  void _onData(Uint8List data) {
    _buf.add(_pending);
    _buf.add(data);
    var bytes = _buf.takeBytes();
    var offset = 0;
    while (bytes.length - offset >= 4) {
      final len = ByteData.sublistView(bytes, offset, offset + 4).getUint32(0);
      if (len > maxFrame) {
        _fail(TransportException('frame too large'));
        _socket.destroy();
        return;
      }
      if (bytes.length - offset - 4 < len) break;
      _push(Uint8List.fromList(bytes.sublist(offset + 4, offset + 4 + len)));
      offset += 4 + len;
    }
    _pending = Uint8List.fromList(bytes.sublist(offset));
  }

  @override
  Future<void> send(Uint8List frame) async {
    if (_error != null) throw _error!;
    final header = ByteData(4)..setUint32(0, frame.length);
    try {
      _socket.add(header.buffer.asUint8List());
      _socket.add(frame);
      await _socket.flush();
    } catch (e) {
      throw TransportException('send failed: $e');
    }
  }

  @override
  Future<Uint8List> receive({Duration timeout = const Duration(seconds: 30)}) => _next(timeout);

  @override
  Future<void> close() async {
    try {
      await _socket.flush();
    } catch (_) {}
    await _socket.close().catchError((_) => _socket);
    _socket.destroy();
    await _sub.cancel();
    _fail(TransportException('closed'));
  }

  @override
  String get remoteAddress {
    try {
      return _socket.remoteAddress.address;
    } catch (_) {
      return '?';
    }
  }
}

/// In-process channel pair, used by tests. [dropAfter] simulates a
/// connection loss after the given number of frames sent by side A.
class MemoryFrameChannel with _FrameQueue implements FrameChannel {
  MemoryFrameChannel? _other;
  bool _closed = false;
  int? dropAfter;
  int _sent = 0;

  MemoryFrameChannel._();

  static (MemoryFrameChannel, MemoryFrameChannel) pair() {
    final a = MemoryFrameChannel._();
    final b = MemoryFrameChannel._();
    a._other = b;
    b._other = a;
    return (a, b);
  }

  @override
  Future<void> send(Uint8List frame) async {
    if (_closed) throw TransportException('closed');
    if (dropAfter != null && _sent >= dropAfter!) {
      await close();
      throw TransportException('connection dropped');
    }
    _sent++;
    await Future<void>.delayed(Duration.zero);
    _other?._push(Uint8List.fromList(frame));
  }

  @override
  Future<Uint8List> receive({Duration timeout = const Duration(seconds: 30)}) => _next(timeout);

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _fail(TransportException('closed'));
    _other?._fail(TransportException('connection closed'));
  }

  @override
  String get remoteAddress => 'memory';
}
