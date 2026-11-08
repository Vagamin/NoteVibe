import 'dart:convert';
import 'dart:async';
import 'package:crypto/crypto.dart';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../app_version.dart';
import '../data/temporary_cache.dart';

/// GitHub repository that publishes the release builds.
const updateRepo = 'Vagamin/NoteVibe';

class UpdateException implements Exception {
  final String message;
  const UpdateException(this.message);
  @override
  String toString() => message;
}

class ReleaseAsset {
  final String name;
  final String url;
  final int size;
  final String? digest;
  const ReleaseAsset({required this.name, required this.url, required this.size, this.digest});
}

class Release {
  final String version;
  final String notes;
  final String pageUrl;
  final List<ReleaseAsset> assets;
  const Release({required this.version, required this.notes, required this.pageUrl, required this.assets});

  factory Release.fromJson(Map<String, dynamic> j) => Release(
        version: (j['tag_name'] as String).replaceFirst(RegExp(r'^v'), ''),
        notes: (j['body'] as String?) ?? '',
        pageUrl: (j['html_url'] as String?) ?? 'https://github.com/$updateRepo/releases',
        assets: [
          for (final a in (j['assets'] as List? ?? const []).cast<Map<String, dynamic>>())
            ReleaseAsset(
              name: a['name'] as String,
              url: a['browser_download_url'] as String,
               size: (a['size'] as num?)?.toInt() ?? 0,
               digest: a['digest'] as String?,
            ),
        ],
      );
}

/// Checks GitHub Releases and downloads the matching Android APK or Windows portable exe.
class UpdateService {
  UpdateService._();

  static const _channel = MethodChannel('notevibe/update');

  static Future<Release> fetchLatest() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client
          .getUrl(Uri.parse('https://api.github.com/repos/$updateRepo/releases/latest'));
      req.headers
        ..set(HttpHeaders.cacheControlHeader, 'no-cache')
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set(HttpHeaders.userAgentHeader, 'NoteVibe/$appVersion');
      final res = await req.close();
      final body = await utf8.decodeStream(res);
      if (res.statusCode == 404) {
        throw const UpdateException('Релизы не найдены или репозиторий закрыт для просмотра.');
      }
      if (res.statusCode != 200) {
        throw UpdateException('GitHub ответил кодом ${res.statusCode}.');
      }
      return Release.fromJson(jsonDecode(body) as Map<String, dynamic>);
    } on SocketException {
      throw const UpdateException('Нет доступа к GitHub. Проверьте интернет.');
    } finally {
      client.close(force: true);
    }
  }

  /// True when [remote] is a higher version than [local] (e.g. "1.0.6" vs "1.0.5").
  static bool isNewer(String remote, String local) {
    List<int> parts(String v) =>
        v.split('+').first.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final a = parts(remote);
    final b = parts(local);
    for (var i = 0; i < 3; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }

  /// Picks the file for this platform, or null if the release has none.
  static ReleaseAsset? pickAsset(Release r, {String abi = ''}) {
    if (Platform.isAndroid) {
      final suffix = switch (abi) {
        'armeabi-v7a' => 'armeabi-v7a.apk',
        'x86_64' => 'x86_64.apk',
        _ => 'arm64.apk',
      };
      for (final a in r.assets) {
        if (a.name.endsWith(suffix)) return a;
      }
      return null;
    }
    if (Platform.isWindows) {
      for (final a in r.assets) {
        if (a.name.toLowerCase() == 'notevibe.exe') return a;
      }
      for (final a in r.assets) {
        if (a.name.endsWith('-portable.exe')) return a;
      }
    }
    return null;
  }

  static Future<String> androidAbi() async =>
      await _channel.invokeMethod<String>('abi') ?? '';

  static Future<File> download(
    ReleaseAsset a,
    Directory dir,
    void Function(double) onProgress,
  ) async {
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, a.name));
    TemporaryCache.retain(file.path);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    Future<bool> valid() async {
      if (!await file.exists()) return false;
      if (a.size > 0 && await file.length() != a.size) return false;
      final expected = a.digest;
      if (expected != null && expected.startsWith('sha256:')) {
        return (await sha256.bind(file.openRead()).first).toString() == expected.substring(7).toLowerCase();
      }
      return true;
    }
    try {
      for (var attempt = 0; attempt < 6; attempt++) {
        try {
          var got = await file.exists() ? await file.length() : 0;
          if (a.size > 0 && got == a.size) {
            if (await valid()) return file;
            await file.delete();
            got = 0;
          }
          if (a.size > 0 && got > a.size) { await file.delete(); got = 0; }
          final req = await client.getUrl(Uri.parse(a.url));
          req.headers.set(HttpHeaders.userAgentHeader, 'NoteVibe/$appVersion');
          if (got > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$got-');
          final res = await req.close().timeout(const Duration(seconds: 30));
          if (res.statusCode != 200 && res.statusCode != 206) {
            await res.drain<void>();
            throw UpdateException('Не удалось скачать файл (код ${res.statusCode}).');
          }
          if (res.statusCode == 206) {
            final range = res.headers.value(HttpHeaders.contentRangeHeader) ?? '';
            if (!range.startsWith('bytes $got-')) {
              await res.drain<void>();
              await file.delete();
              throw const UpdateException('Сервер вернул неверный диапазон файла.');
            }
          } else {
            // A server without Range support must restart, never append a full APK.
            got = 0;
          }
          final sink = file.openWrite(mode: got > 0 ? FileMode.append : FileMode.write);
          try {
            await for (final chunk in res.timeout(const Duration(seconds: 30))) {
              sink.add(chunk);
              got += chunk.length;
              if (a.size > 0) onProgress(got / a.size);
            }
          } finally {
            await sink.close();
          }
          if (a.size > 0 && await file.length() != a.size) {
            throw const UpdateException('Загрузка прервана. Продолжаем скачивание…');
          }
          if (!await valid()) {
            await file.delete();
            throw const UpdateException('Файл обновления повреждён. Скачиваем заново.');
          }
          return file;
        } catch (_) {
          if (attempt == 5) rethrow;
          await Future<void>.delayed(Duration(seconds: 2 * (attempt + 1)));
        }
      }
      throw const UpdateException('Не удалось завершить загрузку. Повторите попытку.');
    } finally {
      client.close(force: true);
      TemporaryCache.protectFor(file.path, const Duration(days: 1));
      TemporaryCache.release(file.path);
    }
  }

  static Future<Directory> downloadDir() async {
    final tmp = await getTemporaryDirectory();
    return Directory(p.join(tmp.path, 'updates'));
  }

  // ------------------------------------------------------------ Android

  static Future<bool> canInstallApks() async =>
      await _channel.invokeMethod<bool>('canInstall') ?? false;

  static Future<void> openInstallSettings() => _channel.invokeMethod('openInstallSettings');

  static Future<void> installApk(File apk) =>
      _channel.invokeMethod('installApk', {'path': apk.path});

  // ------------------------------------------------------------ Windows

  /// Path of the portable launcher the user starts, or null for other builds.
  static String? windowsLauncherPath() {
    final f = File(p.join(File(Platform.resolvedExecutable).parent.path, 'portable.json'));
    if (!f.existsSync()) return null;
    try {
      final path = (jsonDecode(f.readAsStringSync()) as Map)['launcher'] as String?;
      return path != null && File(path).existsSync() ? path : null;
    } catch (_) {
      return null;
    }
  }

  /// Uses a stable filename in the same folder, keeping portable data in place.
  /// Returns the new launcher path; legacy shortcuts need to be recreated once.
  static Future<String> replaceWindowsLauncher(File downloaded, String launcherPath) async {
    final target = File(p.join(p.dirname(launcherPath), 'NoteVibe.exe'));
    final staged = File('${target.path}.${DateTime.now().microsecondsSinceEpoch}.new');
    final backup = File('${staged.path}.backup');
    await downloaded.copy(staged.path);
    try {
      if (await target.exists()) await target.rename(backup.path);
      try {
        await staged.rename(target.path);
      } catch (_) {
        if (await backup.exists()) await backup.rename(target.path);
        rethrow;
      }
    } finally {
      if (await staged.exists()) await staged.delete();
    }
    if (await backup.exists()) await backup.delete();
    // On Windows the filename may differ only in case. Never delete that file.
    if (p.normalize(launcherPath).toLowerCase() != p.normalize(target.path).toLowerCase()) {
      final legacy = File(launcherPath);
      if (await legacy.exists()) await legacy.delete();
    }
    await downloaded.delete();
    return target.path;
  }

  static Future<void> launchWindows(String path) =>
      Process.start(path, const [], mode: ProcessStartMode.detached);

  // ------------------------------------------------------------ links

  static Future<void> openUrl(String url) async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod('openUrl', {'url': url});
    } else if (Platform.isWindows) {
      await Process.start('rundll32', ['url.dll,FileProtocolHandler', url], mode: ProcessStartMode.detached);
    }
  }
}
