import 'dart:io';

import 'package:cryptography/cryptography.dart';

import 'vault_database.dart';

/// Append-only snapshot generations. A verified encrypted snapshot is published
/// by rename, so an interrupted new generation never replaces the last
/// committed one. This directory must have exactly one writer.
class VaultSnapshots {
  final Directory directory;
  final SecretKey key;
  bool _writing = false;
  VaultSnapshots(this.directory, this.key);

  static final _committed = RegExp(r'^snapshot-(\d{12})\.nhv$');

  Future<List<int>> generations() async {
    if (!await directory.exists()) return [];
    final result = <int>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      final match = _committed.firstMatch(name);
      if (match != null) result.add(int.parse(match[1]!));
    }
    result.sort();
    return result;
  }

  File _file(int generation) => File('${directory.path}/snapshot-${generation.toString().padLeft(12, '0')}.nhv');

  /// No fallback on authentication failure: a damaged latest generation is
  /// reported, rather than silently rolling the user's notes back in time.
  Future<VaultDatabase> restoreLatest() async {
    final all = await generations();
    if (all.isEmpty) throw const FileSystemException('Нет сохранённых снимков базы');
    return VaultDatabase.restore(_file(all.last), key);
  }

  /// Explicit recovery, to be offered with a data-loss warning by the UI.
  Future<VaultDatabase> restoreGeneration(int generation) async {
    if (!(await generations()).contains(generation)) {
      throw const FileSystemException('Снимок не найден');
    }
    return VaultDatabase.restore(_file(generation), key);
  }

  Future<int> save(VaultDatabase database) async {
    if (_writing) throw StateError('Сохранение уже выполняется');
    _writing = true;
    Directory? staging;
    try {
      await directory.create(recursive: true);
      final all = await generations();
      final next = all.isEmpty ? 1 : all.last + 1;
      if (next > 999999999999) throw StateError('Исчерпаны номера снимков');
      staging = await directory.createTemp('.pending-');
      final candidate = File('${staging.path}/database.nhv');
      await database.snapshot(candidate, key);
      final verified = await VaultDatabase.restore(candidate, key);
      verified.dispose();
      final destination = _file(next);
      if (await FileSystemEntity.type(destination.path, followLinks: false) != FileSystemEntityType.notFound) {
        throw const FileSystemException('Конфликт сохранения снимка');
      }
      // Same-volume rename publishes a fully written, flushed and verified
      // encrypted container. Older generations are intentionally not deleted.
      await candidate.rename(destination.path);
      return next;
    } finally {
      _writing = false;
      if (staging != null && await staging.exists()) await staging.delete(recursive: true);
    }
  }
}
