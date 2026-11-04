import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/update/update_service.dart';

void main() {
  test('update download resumes an interrupted response with Range', () async {
    final dir = await Directory.systemTemp.createTemp('nv_update');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final bytes = List.generate(1000, (i) => i % 256);
    var requests = 0;
    final subscription = server.listen((req) async {
      requests++;
      if (requests == 1) {
        req.response.add(bytes.take(400).toList());
      } else {
        expect(req.headers.value(HttpHeaders.rangeHeader), 'bytes=400-');
        req.response.statusCode = 206;
        req.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes 400-999/1000');
        req.response.add(bytes.skip(400).toList());
      }
      await req.response.close();
    });
    try {
      final file = await UpdateService.download(ReleaseAsset(name: 'test.apk',
        url: 'http://127.0.0.1:${server.port}/update', size: bytes.length), dir, (_) {});
      expect(await file.readAsBytes(), bytes);
      expect(requests, 2);
    } finally {
      await subscription.cancel();
      await server.close(force: true);
      await dir.delete(recursive: true);
    }
  });
}
