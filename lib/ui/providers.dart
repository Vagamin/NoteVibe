import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../data/attachment_storage.dart';
import '../data/note_store.dart';
import '../data/vault/vault_mode.dart';
import '../data/vault/vault_session.dart';
import '../data/vault/vault_key_store.dart';
import '../data/vault/vault_lock.dart';
import '../data/vault/vault_transition.dart';
import '../domain/note.dart';
import '../sync/crypto/dpapi_key_store.dart';
import '../sync/crypto/keys.dart';
import '../sync/discovery/lan_discovery.dart';
import '../sync/sync_service.dart';

/// Everything created once at startup.
class AppServices {
  final NoteStore store;
  final SyncService sync;
  final AttachmentStorage attachments;
  final VaultSession? vault;
  final Directory? dataDirectory;
  final KeyStore? legacyKeys;
  final VaultLock? applicationLock;
  final List<String> startupArgs;
  final pendingEditors = <void Function()>{};
  bool _closed = false;
  bool transitioning = false;
  bool mobileLocked = false;
  final lockHandlers = <Future<void> Function()>{};
  AppServices(this.store, this.sync, this.attachments, {this.vault,
    this.dataDirectory, this.legacyKeys, this.applicationLock, this.startupArgs = const []});

  Future<void> flush() async {
    for (final save in pendingEditors.toList()) { save(); }
    // NoteStore broadcasts are asynchronous; deliver revisions before flush.
    await Future<void>.delayed(Duration.zero);
    await vault?.notes.flush();
  }

  Future<void> close({bool releaseLock = true}) async {
    if (_closed) return;
    await flush();
    await sync.dispose();
    if (vault != null) { await vault!.close(); } else { store.dispose(); }
    if (releaseLock) await applicationLock?.release();
    _closed = true;
  }

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

  static Future<AppServices> init([List<String> args = const [], String? vaultPassword]) async {
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
    KeyStore keyStore = Platform.isWindows && (portable != null || await File(p.join(dir.path, 'keys.dpapi.json')).exists())
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
    VaultLock? appLock;
    if (Platform.isWindows || Platform.isAndroid) appLock = await VaultLock.acquire(dir);
    try {
    if ((Platform.isWindows || Platform.isAndroid) && await VaultTransition.pending(dir) != null) {
      if (Platform.isAndroid) {
        await const MethodChannel('notevibe/update').invokeMethod<void>('vaultSecureScreen', {'enabled': true});
      }
      final tmp = await getTemporaryDirectory();
      await VaultTransition.recover(dir, deviceId: deviceId, password: vaultPassword, keys: keyStore,
        caches: [Directory(p.join(tmp.path, 'notevibe_play')), Directory(p.join(tmp.path, 'notevibe_gallery')), Directory(p.join(tmp.path, 'notevibe_clipboard')),
          Directory(p.join(Directory.systemTemp.path, 'notevibe_open'))]);
    }
    final encrypted = (Platform.isWindows || Platform.isAndroid) && await VaultMode.encrypted(dir);
    if (Platform.isAndroid) {
      await const MethodChannel('notevibe/update').invokeMethod<void>('vaultSecureScreen', {'enabled': encrypted});
    }
    if (!encrypted && Platform.isWindows && await File(p.join(dir.path, 'keys.dpapi.json')).exists()) {
      keyStore = DpapiFileKeyStore(File(p.join(dir.path, 'keys.dpapi.json')));
    }
    if (encrypted && vaultPassword == null) throw const VaultLocked();
    final vault = encrypted ? await VaultSession.unlock(Directory(p.join(dir.path, 'vault')),
      vaultPassword!, deviceId: deviceId) : null;
    final store = vault?.notes.store ?? NoteStore.open(p.join(dir.path, 'notevibe.db'), deviceId: deviceId);
    SyncService? startedSync;
    try {
    final attachments = vault?.attachments ?? AttachmentStorage(Directory(dir.path));
    final unlockedKeyStore = vault == null ? keyStore : VaultKeyStore(
      Directory(p.join(dir.path, 'vault', 'keys')), vault.notes.snapshots.key);
    if (vault != null) {
      final seed = await unlockedKeyStore.read('identity_x25519');
      if (seed == null || seed.length != 32) {
        throw const FormatException('Ключ идентификации отсутствует или повреждён. Требуется восстановить миграцию');
      }
    }
    final name = store.getSetting('device_name') ?? _defaultName();
    final identity = await DeviceIdentity.loadOrCreate(unlockedKeyStore, deviceId, name);
    final sync = SyncService(
      store: store,
      peerKeys: PeerKeys(unlockedKeyStore),
      identity: identity,
      files: attachments,
    );
    startedSync = sync;
    try {
      await sync.start();
    } catch (e) {
      debugPrint('Sync start failed: $e');
    }
    store.pruneChangeLog();
    store.purgeExpiredTrash();
    return AppServices(store, sync, attachments, vault: vault, dataDirectory: dir,
      legacyKeys: keyStore, applicationLock: appLock, startupArgs: args);
    } catch (_) {
      try {
        await startedSync?.dispose();
      } finally {
        if (vault != null) {
          await vault.close();
        } else {
          store.dispose();
        }
      }
      rethrow;
    }
    } catch (_) {
      await appLock?.release();
      rethrow;
    }
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

/// Ids of notes picked for a bulk action. Null means selection mode is off.
class NoteSelection extends Notifier<Set<String>?> {
  @override
  Set<String>? build() => null;

  void start() => state = {};

  void toggle(String id) {
    final next = {...?state};
    if (!next.remove(id)) next.add(id);
    state = next;
  }

  void clear() => state = null;
}

final selectionProvider = NotifierProvider<NoteSelection, Set<String>?>(NoteSelection.new);

class TransferSelection extends Notifier<bool> {
  @override
  bool build() => false;
  void set(bool value) => state = value;
}
final transferSelectionProvider = NotifierProvider<TransferSelection, bool>(TransferSelection.new);

class FolderSelection extends Notifier<String?> {
  @override
  String? build() {
    final store = ref.watch(storeProvider);
    final id = store.getSetting('last_folder');
    return id == '' || store.listFolders().any((f) => f.id == id) ? id : null;
  }
  void select(String? id) {
    ref.read(storeProvider).setSetting('last_folder', id ?? '@all');
    state = id;
  }
}
// null = all, empty string = unfiled.
final folderSelectionProvider = NotifierProvider<FolderSelection, String?>(FolderSelection.new);
final foldersEnabledProvider = Provider<bool>((ref) => ref.watch(storeProvider).getSetting('folders_enabled') != 'false');

// Page contents must not depend on the currently selected page: changing the
// title mid-swipe otherwise reloads every visible list from SQLite.
final _boardSourceProvider = Provider<List<Note>>((ref) {
  ref.watch(storeChangesProvider);
  return ref.watch(storeProvider).listNotes(manual: ref.watch(manualOrderProvider));
});
final boardNotesProvider = Provider.autoDispose.family<List<Note>, String?>((ref, id) {
  final notes = ref.watch(_boardSourceProvider);
  if (id == null) return notes;
  final folders = ref.watch(storeProvider).listFolders().map((f) => f.id).toSet();
  return notes.where((n) => id.isEmpty ? !folders.contains(n.folderId) : n.folderId == id).toList();
});

final notesProvider = Provider<List<Note>>((ref) {
  ref.watch(storeChangesProvider);
  final store = ref.watch(storeProvider);
  final query = ref.watch(searchQueryProvider);
  final folder = ref.watch(folderSelectionProvider);
  final notes = store.listNotes(
        query: query,
        manual: ref.watch(manualOrderProvider),
       );
  if (!ref.watch(foldersEnabledProvider) || folder == null || query.trim().isNotEmpty) return notes;
  final folders = store.listFolders().map((f) => f.id).toSet();
  if (folder.isNotEmpty && folders.contains(folder)) return notes.where((n) => n.folderId == folder).toList();
  return notes.where((n) => !folders.contains(n.folderId)).toList();
});

final archivedNotesProvider = Provider<List<Note>>((ref) {
  ref.watch(storeChangesProvider);
  return ref.watch(storeProvider).listArchived(query: ref.watch(searchQueryProvider));
});

final trashedNotesProvider = Provider<List<Note>>((ref) {
  ref.watch(storeChangesProvider);
  return ref.watch(storeProvider).listTrashed(query: ref.watch(searchQueryProvider));
});

/// Whether the list follows the user's own order instead of the date.
class ManualOrderSetting extends Notifier<bool> {
  @override
  bool build() => ref.watch(storeProvider).getSetting('manual_order') == 'true';

  void set(bool v) {
    ref.read(storeProvider).setSetting('manual_order', v ? 'true' : 'false');
    state = v;
  }
}

final manualOrderProvider = NotifierProvider<ManualOrderSetting, bool>(ManualOrderSetting.new);

/// How long deleted notes stay in the trash, in days. 0 deletes at once.
enum TrashPeriod {
  immediately(0, 'Сразу, без корзины'),
  day(1, 'Через 1 день'),
  week(7, 'Через 7 дней'),
  month(30, 'Через 30 дней'),
  never(-1, 'Не удалять');

  /// Days in the trash; -1 keeps notes until the user deletes them.
  final int days;
  final String label;
  const TrashPeriod(this.days, this.label);
}

class TrashPeriodSetting extends Notifier<TrashPeriod> {
  @override
  TrashPeriod build() {
    final v = ref.watch(storeProvider).getSetting(NoteStore.trashDaysSetting);
    final days = int.tryParse(v ?? '');
    return TrashPeriod.values.firstWhere((m) => m.days == days, orElse: () => TrashPeriod.month);
  }

  void set(TrashPeriod p) {
    ref.read(storeProvider).setSetting(NoteStore.trashDaysSetting, '${p.days}');
    state = p;
  }
}

final trashPeriodProvider = NotifierProvider<TrashPeriodSetting, TrashPeriod>(TrashPeriodSetting.new);

/// Microphone used for voice notes (PC only). Empty means the system default.
class CaptureDeviceSetting extends Notifier<String> {
  @override
  String build() => ref.watch(storeProvider).getSetting('capture_device') ?? '';

  void set(String id, String name) {
    ref.read(storeProvider).setSetting('capture_device', id);
    ref.read(storeProvider).setSetting('capture_device_name', name);
    state = id;
  }
}

final captureDeviceProvider = NotifierProvider<CaptureDeviceSetting, String>(CaptureDeviceSetting.new);

final captureDeviceNameProvider = Provider<String>((ref) {
  ref.watch(captureDeviceProvider);
  return ref.watch(storeProvider).getSetting('capture_device_name') ?? '';
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

/// How many lines of a note are shown in the list.
enum PreviewLines {
  titleOnly(0, 'Только заголовок'),
  one(1, '1 строка'),
  two(2, '2 строки'),
  three(3, '3 строки'),
  four(4, '4 строки'),
  five(5, '5 строк'),
  full(-1, 'Вся заметка');

  /// Lines of body text to show under the title. 0 hides the body, -1 shows all.
  final int lines;
  final String label;
  const PreviewLines(this.lines, this.label);
}

class PreviewLinesSetting extends Notifier<PreviewLines> {
  @override
  PreviewLines build() {
    final v = ref.watch(storeProvider).getSetting('preview_lines');
    return PreviewLines.values.firstWhere((m) => m.name == v, orElse: () => PreviewLines.two);
  }

  void set(PreviewLines p) {
    ref.read(storeProvider).setSetting('preview_lines', p.name);
    state = p;
  }
}

final previewLinesProvider = NotifierProvider<PreviewLinesSetting, PreviewLines>(PreviewLinesSetting.new);

enum VoicePreview {
  hidden(0, 'Только количество'),
  one(1, '1 запись'),
  two(2, '2 записи'),
  three(3, '3 записи'),
  four(4, '4 записи'),
  five(5, '5 записей'),
  six(6, '6 записей'),
  seven(7, '7 записей'),
  eight(8, '8 записей'),
  nine(9, '9 записей'),
  ten(10, '10 записей'),
  all(10, 'Все записи');

  final int count;
  final String label;
  const VoicePreview(this.count, this.label);
}

class VoicePreviewSetting extends Notifier<VoicePreview> {
  @override
  VoicePreview build() {
    final value = ref.watch(storeProvider).getSetting('voice_preview');
    return VoicePreview.values.firstWhere((v) => v.name == value, orElse: () => VoicePreview.all);
  }

  void set(VoicePreview value) {
    ref.read(storeProvider).setSetting('voice_preview', value.name);
    state = value;
  }
}

final voicePreviewProvider = NotifierProvider<VoicePreviewSetting, VoicePreview>(VoicePreviewSetting.new);

/// Text size of notes, both in the editor and in the list.
enum NoteFontSize {
  tiny(0.75, 'Очень мелкий'),
  small(0.88, 'Мелкий'),
  normal(1.0, 'Обычный'),
  medium(1.1, 'Чуть крупнее'),
  large(1.2, 'Крупный'),
  huge(1.4, 'Очень крупный'),
  extraLarge(1.6, 'Большой'),
  maximum(1.85, 'Максимальный');

  /// Multiplier applied to the default text size.
  final double scale;
  final String label;
  const NoteFontSize(this.scale, this.label);
}

class NoteFontSizeSetting extends Notifier<NoteFontSize> {
  @override
  NoteFontSize build() {
    final v = ref.watch(storeProvider).getSetting('note_font_size');
    return NoteFontSize.values.firstWhere((m) => m.name == v, orElse: () => NoteFontSize.normal);
  }

  void set(NoteFontSize f) {
    ref.read(storeProvider).setSetting('note_font_size', f.name);
    state = f;
  }
}

final noteFontSizeProvider = NotifierProvider<NoteFontSizeSetting, NoteFontSize>(NoteFontSizeSetting.new);
