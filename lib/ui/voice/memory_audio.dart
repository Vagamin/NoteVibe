import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Native Windows audio backends consume URLs, not Dart byte streams. Expose
/// verified bytes on loopback with an unpredictable per-player URL, never disk.
class MemoryAudio {
  final HttpServer _server;
  final Uint8List _bytes;
  final String url;
  MemoryAudio._(this._server, this._bytes, this.url);

  static Future<MemoryAudio> create(Uint8List bytes, String mime) async {
    final random = Random.secure();
    final token = List.generate(32, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final path = '/$token';
    server.listen((request) async {
      try {
        if (request.uri.path != path || !['GET', 'HEAD'].contains(request.method)) {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }
        var start = 0;
        var end = bytes.length - 1;
        final range = request.headers.value(HttpHeaders.rangeHeader);
        if (range != null) {
          final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
          if (match == null || (start = int.parse(match[1]!)) >= bytes.length ||
              (match[2]!.isNotEmpty && (end = int.parse(match[2]!)) < start)) {
            request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
            await request.response.close();
            return;
          }
          end = end.clamp(start, bytes.length - 1);
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/${bytes.length}');
        }
        request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
        request.response.headers.contentType = ContentType.parse(mime.startsWith('audio/') ? mime : 'application/octet-stream');
        request.response.contentLength = end - start + 1;
        if (request.method == 'GET') request.response.add(bytes.sublist(start, end + 1));
        await request.response.close();
      } catch (_) { request.response.detachSocket().then((s) => s.destroy()).ignore(); }
    });
    return MemoryAudio._(server, bytes, 'http://127.0.0.1:${server.port}$path');
  }

  Future<void> close() async {
    await _server.close(force: true);
    _bytes.fillRange(0, _bytes.length, 0);
  }
}
