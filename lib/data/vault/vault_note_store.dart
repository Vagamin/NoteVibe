import 'dart:async';

import '../note_store.dart';
import 'vault_database.dart';
import 'vault_snapshots.dart';

/// Coordinates a real NoteStore and encrypted snapshot persistence.
/// Edits are synchronous in RAM; callers must await flush() before reporting
/// durable saves or closing. A failed save remains dirty and is retryable.
/// Startup uses this coordinator after an encrypted vault is unlocked.
class VaultNoteStore {
  final VaultDatabase database;
  final VaultSnapshots snapshots;
  final NoteStore store;
  late final StreamSubscription<void> _subscription;
  final _errors = StreamController<Object>.broadcast();
  final _status = StreamController<void>.broadcast();
  Object? lastSaveError;
  Future<void>? _saving;
  int _revision = 1;
  int _savedRevision = 0;
  bool _closing = false;
  bool _closed = false;

  VaultNoteStore(this.database, this.snapshots, {required String deviceId})
      : store = NoteStore.fromVaultDatabase(database.database, deviceId: deviceId) {
    _subscription = store.changes.listen((_) {
      _revision++;
      // Automatic saving has an explicit error channel rather than an
      // unhandled asynchronous failure or a false successful-save indicator.
      unawaited(flush().catchError((Object error) {
        if (!_errors.isClosed) _errors.add(error);
      }));
    });
  }

  Stream<Object> get errors => _errors.stream;
  Stream<void> get persistenceChanges => _status.stream;
  bool get hasUnsavedChanges => _revision != _savedRevision;

  Future<void> flush() {
    if (_closed) return Future.error(StateError('Хранилище закрыто'));
    return _saving ??= _drain();
  }

  Future<void> _drain() async {
    try {
      while (_savedRevision != _revision) {
        final revision = _revision;
        await snapshots.save(database);
        _savedRevision = revision;
      }
      lastSaveError = null;
    } catch (error) {
      lastSaveError = error;
      rethrow;
    } finally {
      _saving = null;
      if (!_status.isClosed) _status.add(null);
    }
  }

  /// Stop sync and editing before calling. Failed flush deliberately leaves
  /// the store open, allowing retry instead of discarding in-memory edits.
  Future<void> close() async {
    if (_closed) return;
    if (_closing) throw StateError('Закрытие уже выполняется');
    _closing = true;
    try {
      await flush();
      await _subscription.cancel();
      store.dispose();
      database.dispose();
      _closed = true;
      await _errors.close();
      await _status.close();
    } finally {
      _closing = false;
    }
  }
}
