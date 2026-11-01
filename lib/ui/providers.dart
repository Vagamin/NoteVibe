import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../data/note_store.dart';
import '../domain/note.dart';
import '../sync/crypto/dpapi_key_store.dart';
import '../sync/crypto/keys.dart';
import '../sync/discovery/lan_discovery.dart';
import '../sync/sync_service.dart';

/// Everything created once at startup.
class AppServices {
  final NoteStore store;
  final SyncService sync;
  AppServices(this.store, this.sync);

  /// Data folder for the portable build: `--data-dir <path>` (passed by the
  /// single-file launcher) or a `NoteVibe-Data` folder next to the exe.
  static Directory? portableDataDir(List<String> args) {
    final i = args.indexOf('--data-dir');
    if (i >= 0 && i + 1 < args.length) return Directory(args[i + 1]);
    if (Platform.isWindows) {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final d = Directory(p.join(exeDir, 'NoteVibe-Data'));
      if (d.existsSync()) return d;
      final marker = File(p.join(exeDir, 'portable.json'));
      if (marker.existsSync()) {
        try {
          final path = (jsonDecode(marker.readAsStringSync()) as Map)['dataDir'] as String?;
          if (path != null && path.isNotEmpty) return Directory(path);
        } catch (_) {}
      }
    }
    return null;
  }

  static Future<AppServices> init([List<String> args = const []]) async {
    if (Platform.isAndroid) {
      try {
        await const MethodChannel('notevibe/net').invokeMethod('acquireMulticast');
      } catch (e) {
        debugPrint('MulticastLock failed: $e');
      }
    }
    final portable = portableDataDir(args);
    final dir = portable ?? await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    final KeyStore keyStore = portable != null && Platform.isWindows
        ? DpapiFileKeyStore(File(p.join(dir.path, 'keys.dpapi.json')))
        : SecureKeyStore();

    // Device id lives next to the DB; the private key lives in secure storage.
    final idFile = File(p.join(dir.path, 'device_id'));
    String deviceId;
    if (await idFile.exists()) {
      deviceId = (await idFile.readAsString()).trim();
    } else {
      deviceId = const Uuid().v4();
      await idFile.writeAsString(deviceId, flush: true);
    }
    final store = NoteStore.open(p.join(dir.path, 'notevibe.db'), deviceId: deviceId);
    final name = store.getSetting('device_name') ?? _defaultName();
    final identity = await DeviceIdentity.loadOrCreate(keyStore, deviceId, name);
    final sync = SyncService(store: store, peerKeys: PeerKeys(keyStore), identity: identity);
    try {
      await sync.start();
    } catch (e) {
      debugPrint('Sync start failed: $e');
    }
    store.pruneChangeLog();
    return AppServices(store, sync);
  }

  static String _defaultName() {
    if (Platform.isAndroid) return 'Телефон';
    try {
      return Platform.localHostname;
    } catch (_) {
      return 'Компьютер';
    }
  }
}

final servicesProvider = Provider<AppServices>((ref) => throw UnimplementedError());

final storeProvider = Provider<NoteStore>((ref) => ref.watch(servicesProvider).store);
final syncProvider = Provider<SyncService>((ref) => ref.watch(servicesProvider).sync);

/// Ticks on every store change, so dependent providers re-query.
final storeChangesProvider = StreamProvider<int>((ref) async* {
  var i = 0;
  yield i;
  await for (final _ in ref.watch(storeProvider).changes) {
    yield ++i;
  }
});

class SearchQuery extends Notifier<String> {
  @override
  String build() => '';
  void set(String q) => state = q;
}

final searchQueryProvider = NotifierProvider<SearchQuery, String>(SearchQuery.new);

final notesProvider = Provider<List<Note>>((ref) {
  ref.watch(storeChangesProvider);
  return ref.watch(storeProvider).listNotes(query: ref.watch(searchQueryProvider));
});

class SelectedNote extends Notifier<String?> {
  @override
  String? build() => null;
  void select(String? id) => state = id;
}

final selectedNoteProvider = NotifierProvider<SelectedNote, String?>(SelectedNote.new);

final syncStatusProvider = StreamProvider<SyncStatus>((ref) {
  final s = ref.watch(syncProvider);
  final ctl = StreamController<SyncStatus>();
  ctl.add(s.currentStatus);
  final sub = s.status.listen(ctl.add);
  ref.onDispose(() {
    sub.cancel();
    ctl.close();
  });
  return ctl.stream;
});

final discoveredProvider = StreamProvider<List<DiscoveredDevice>>((ref) {
  final s = ref.watch(syncProvider);
  final ctl = StreamController<List<DiscoveredDevice>>();
  ctl.add(s.currentDiscovered);
  final sub = s.discovered.listen(ctl.add);
  ref.onDispose(() {
    sub.cancel();
    ctl.close();
  });
  return ctl.stream;
});

class ThemeModeSetting extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    final v = ref.watch(storeProvider).getSetting('theme');
    return ThemeMode.values.firstWhere((m) => m.name == v, orElse: () => ThemeMode.system);
  }

  void set(ThemeMode m) {
    ref.read(storeProvider).setSetting('theme', m.name);
    state = m;
  }
}

final themeModeProvider = NotifierProvider<ThemeModeSetting, ThemeMode>(ThemeModeSetting.new);
