import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/data/temporary_cache.dart';

void main() {
  late Directory dir;
  late Directory cacheDir;
  final now = DateTime(2026, 11, 4);
  late TemporaryCache cache;

  Future<File> file(String name, {int size = 10, int days = 0}) async {
    final f = File('${cacheDir.path}/$name');
    await f.writeAsBytes(List.filled(size, 1));
    await f.setLastModified(now.subtract(Duration(days: days)));
    return f;
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('nv_cache_test');
    cacheDir = await Directory('${dir.path}/owned').create();
    cache = TemporaryCache([cacheDir], installedVersion: '1.1.5', clock: () => now);
  });
  tearDown(() async => dir.delete(recursive: true));

  test('daily cleanup expires copies but never touches originals outside roots', () async {
    final old = await file('old.wav', days: 2);
    final fresh = await file('fresh.wav');
    final original = await File('${dir.path}/original.wav').writeAsBytes([1, 2]);
    await cache.clean();
    expect(await old.exists(), isFalse);
    expect(await fresh.exists(), isTrue);
    expect(await original.exists(), isTrue);
  });

  test('installed APKs removed independently of daily interval; pending installer protected', () async {
    final old = await file('NoteVibe-1.1.4-arm64.apk');
    final installed = await file('NoteVibe-1.1.5-arm64.apk');
    final pending = await file('NoteVibe-1.1.6-arm64.apk');
    await cache.clean(maintenance: false);
    expect(await old.exists(), isFalse);
    expect(await installed.exists(), isFalse);
    expect(await pending.exists(), isTrue);
    await cache.clean(all: true);
    expect(await pending.exists(), isTrue);
  });

  test('size limit evicts oldest files first', () async {
    final a = await file('a', size: 30);
    final b = await file('b', size: 30);
    await a.setLastModified(now.subtract(const Duration(hours: 2)));
    await cache.clean(limit: 35);
    expect(await a.exists(), isFalse);
    expect(await b.exists(), isTrue);
    expect(await cache.sizeBytes(), 30);
  });

  test('manual clear respects multiple playback leases', () async {
    final a = await file('playing.wav', days: 2);
    TemporaryCache.retain(a.path);
    TemporaryCache.retain(a.path);
    await cache.clean(all: true);
    expect(await a.exists(), isTrue);
    TemporaryCache.release(a.path);
    await cache.clean(all: true);
    expect(await a.exists(), isTrue);
    TemporaryCache.release(a.path);
    await cache.clean(all: true);
    expect(await a.exists(), isFalse);
  });
}
