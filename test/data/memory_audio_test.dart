import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/ui/voice/memory_audio.dart';

void main() {
  test('memory audio serves ranges only on its secret loopback URL', () async {
    final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);
    final source = await MemoryAudio.create(bytes, 'audio/wav');
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(source.url));
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=1-3');
      final response = await request.close();
      expect(response.statusCode, HttpStatus.partialContent);
      expect(await response.expand((b) => b).toList(), [2, 3, 4]);
      final wrong = await client.getUrl(Uri.parse(source.url).replace(path: '/wrong'));
      final refused = await wrong.close();
      expect(refused.statusCode, HttpStatus.notFound);
      await refused.drain<void>();
      final invalid = await client.getUrl(Uri.parse(source.url));
      invalid.headers.set(HttpHeaders.rangeHeader, 'bytes=100-');
      final invalidResponse = await invalid.close();
      expect(invalidResponse.statusCode, HttpStatus.requestedRangeNotSatisfiable);
      await invalidResponse.drain<void>();
    } finally {
      client.close(force: true);
      await source.close();
    }
    expect(bytes, [0, 0, 0, 0, 0]);
  });
}
