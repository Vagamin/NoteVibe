import 'dart:io';

import 'package:path/path.dart' as p;

/// Only these application-owned temporary directories may be cleaned.
/// Never pass the attachments/data directory as a root.
class TemporaryCache {
  final List<Directory> roots;
  final String installedVersion;
  final DateTime Function() clock;
  static final _leases = <String, int>{};
  static final _until = <String, DateTime>{};

  TemporaryCache(this.roots, {required this.installedVersion, DateTime Function()? clock})
      : clock = clock ?? DateTime.now;

  static String _key(String path) => p.normalize(p.absolute(path));

  static void retain(String path) {
    final key = _key(path);
    _leases[key] = (_leases[key] ?? 0) + 1;
  }

  static void release(String path) {
    final key = _key(path);
    final count = (_leases[key] ?? 0) - 1;
    if (count <= 0) { _leases.remove(key); } else { _leases[key] = count; }
  }

  static void protectFor(String path, Duration duration) {
    _until[_key(path)] = DateTime.now().add(duration);
  }

  bool _protected(File file) {
    final key = _key(file.path);
    return _leases.containsKey(key) || (_until[key]?.isAfter(clock()) ?? false);
  }

  Future<List<File>> _files() async {
    final result = <File>[];
    for (final root in roots) {
      if (!await root.exists()) continue;
      // No symlink traversal or unrelated files outside our private subfolders.
      await for (final entry in root.list(followLinks: false)) {
        if (entry is File) result.add(entry);
      }
    }
    return result;
  }

  Future<int> sizeBytes() async {
    var size = 0;
    for (final file in await _files()) {
      try { size += await file.length(); } on FileSystemException { /* raced with a writer */ }
    }
    return size;
  }

  bool _installedApk(File file) {
    final match = RegExp(r'^NoteVibe-(\d+\.\d+\.\d+)-.*\.apk$').firstMatch(p.basename(file.path));
    if (match == null) return false;
    final a = match[1]!.split('.').map(int.parse).toList();
    final b = installedVersion.split('.').map(int.parse).toList();
    for (var i = 0; i < 3; i++) {
      if (a[i] != b[i]) return a[i] < b[i];
    }
    return true;
  }

  /// Installed APKs are removed even when daily maintenance isn't due.
  /// Other installers get a seven-day grace period for external installers.
  Future<void> clean({bool all = false, bool maintenance = true, int limit = 50 * 1024 * 1024}) async {
    final files = await _files();
    final stats = <File, FileStat>{};
    for (final file in files) {
      try { stats[file] = await file.stat(); } on FileSystemException { /* disappeared */ }
    }
    final ordered = stats.keys.toList()..sort((a, b) => stats[a]!.modified.compareTo(stats[b]!.modified));
    var total = stats.values.fold<int>(0, (n, stat) => n + stat.size);
    for (final file in ordered) {
      if (_protected(file)) continue;
      final apk = p.extension(file.path).toLowerCase() == '.apk';
      final age = clock().difference(stats[file]!.modified);
      if (apk && !_installedApk(file) && age < const Duration(days: 7)) continue;
      if (!all && !_installedApk(file) && !(maintenance && (age >= const Duration(days: 1) || total > limit))) continue;
      try {
        await file.delete();
        total -= stats[file]!.size;
      } on FileSystemException { /* locked/in use: retry next time */ }
    }
  }
}
