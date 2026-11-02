import 'dart:async';
import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import '../domain/attachment.dart';
import '../domain/conflict.dart';
import '../domain/note.dart';
import '../domain/peer.dart';
import '../domain/version_vector.dart';
import 'schema.dart';

class ApplyResult {
  int applied = 0;
  int ignored = 0;
  int conflicts = 0;
  @override
  String toString() => 'ApplyResult(applied=$applied, ignored=$ignored, conflicts=$conflicts)';
}

/// SQLite-backed storage for notes, change log, conflicts, peers and settings.
///
/// Every mutation runs in a single transaction which updates the note,
/// appends to `change_log` and assigns the note a new monotonically
/// increasing `seq`. Sync uses `seq` as a resumable cursor.
class NoteStore {
  final Database _db;
  final String deviceId;
  final DateTime Function() _now;
  final _changes = StreamController<void>.broadcast(sync: true);
  static const _uuid = Uuid();

  NoteStore._(this._db, this.deviceId, this._now);

  static NoteStore open(String path, {required String deviceId, DateTime Function()? now}) {
    final db = sqlite3.open(path);
    db.execute('PRAGMA foreign_keys=ON;');
    migrate(db, backupPath: path);
    db.execute('PRAGMA journal_mode=WAL;');
    db.execute('PRAGMA synchronous=NORMAL;');
    return NoteStore._(db, deviceId, now ?? DateTime.now);
  }

  static NoteStore inMemory({required String deviceId, DateTime Function()? now}) =>
      NoteStore._init(sqlite3.openInMemory(), deviceId, now);

  static NoteStore _init(Database db, String deviceId, DateTime Function()? now) {
    db.execute('PRAGMA foreign_keys=ON;');
    migrate(db);
    return NoteStore._(db, deviceId, now ?? DateTime.now);
  }

  /// Emits whenever notes, conflicts or peers change.
  Stream<void> get changes => _changes.stream;

  void dispose() {
    _changes.close();
    _db.close();
  }

  T _tx<T>(T Function() body) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      final r = body();
      _db.execute('COMMIT');
      return r;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  // ---------------------------------------------------------------- notes

  static const _noteCols =
      'id, title, content, plain, created, updated, vv, dev, deleted, important, archived, '
      '(SELECT COUNT(*) FROM conflicts c WHERE c.note_id = notes.id) AS nconf';

  Note _rowToNote(Row r) => Note(
        id: r['id'] as String,
        title: r['title'] as String,
        content: r['content'] as String,
        plainText: r['plain'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(r['created'] as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(r['updated'] as int),
        version: VersionVector.decode(r['vv'] as String),
        lastDevice: r['dev'] as String,
        deleted: (r['deleted'] as int) != 0,
        important: (r['important'] as int) != 0,
        archived: (r['archived'] as int) != 0,
        hasConflict: ((r['nconf'] as int?) ?? 0) > 0,
      );

  Note? getNote(String id) {
    final rs = _db.select('SELECT $_noteCols FROM notes WHERE id = ?', [id]);
    return rs.isEmpty ? null : _rowToNote(rs.first);
  }

  /// Lists non-deleted notes that are not archived: important first, then newest.
  /// [query] does a case-insensitive substring search in title and text
  /// (Unicode-aware).
  List<Note> listNotes({String query = ''}) => _listWhere(archived: false, query: query);

  /// Lists archived notes, newest first.
  List<Note> listArchived({String query = ''}) => _listWhere(archived: true, query: query);

  List<Note> _listWhere({required bool archived, required String query}) {
    final q = query.trim().toLowerCase();
    final flag = archived ? 1 : 0;
    final rs = q.isEmpty
        ? _db.select(
            'SELECT $_noteCols FROM notes WHERE deleted = 0 AND archived = ? '
            'ORDER BY important DESC, updated DESC',
            [flag])
        : _db.select(
            'SELECT $_noteCols FROM notes WHERE deleted = 0 AND archived = ? AND instr(search, ?) > 0 '
            'ORDER BY important DESC, updated DESC',
            [flag, q]);
    return rs.map(_rowToNote).toList();
  }

  /// Moves notes to or from the archive in one change. Syncs like any edit.
  void setArchived(Iterable<String> ids, bool value) {
    _tx(() {
      for (final id in ids) {
        final cur = getNote(id);
        if (cur == null || cur.deleted || cur.archived == value) continue;
        final next = cur.copyWith(
          archived: value,
          updatedAt: _now(),
          version: cur.version.increment(deviceId),
          lastDevice: deviceId,
        );
        final seq = _appendLog(id, 'upsert', next.version, deviceId);
        _writeNote(next, seq);
      }
    });
    _notify();
  }

  /// Sets or clears the importance flag. It is a regular edit, so it syncs.
  void setImportant(String id, bool value) {
    _tx(() {
      final cur = getNote(id);
      if (cur == null || cur.deleted || cur.important == value) return;
      final next = cur.copyWith(
        important: value,
        updatedAt: _now(),
        version: cur.version.increment(deviceId),
        lastDevice: deviceId,
      );
      final seq = _appendLog(id, 'upsert', next.version, deviceId);
      _writeNote(next, seq);
    });
    _notify();
  }

  int _appendLog(String noteId, String op, VersionVector vv, String device) {
    _db.execute(
      'INSERT INTO change_log (note_id, op, vv, device, at) VALUES (?, ?, ?, ?, ?)',
      [noteId, op, vv.encode(), device, _now().millisecondsSinceEpoch],
    );
    return _db.lastInsertRowId;
  }

  /// [src] is the peer a remote version was received from (null for local
  /// edits); it lets sync avoid echoing a note back to where it came from.
  void _writeNote(Note n, int seq, {List<String>? dismissed, String? src}) {
    dismissed ??= _dismissed(n.id);
    _db.execute(
      'INSERT INTO notes (id, title, content, plain, search, created, updated, vv, dev, deleted, important, archived, seq, src, dismissed) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET title=excluded.title, content=excluded.content, '
      'plain=excluded.plain, search=excluded.search, created=excluded.created, '
      'updated=excluded.updated, vv=excluded.vv, dev=excluded.dev, deleted=excluded.deleted, '
      'important=excluded.important, archived=excluded.archived, seq=excluded.seq, src=excluded.src, dismissed=excluded.dismissed',
      [
        n.id,
        n.title,
        n.content,
        n.plainText,
        '${n.title}\n${n.plainText}'.toLowerCase(),
        n.createdAt.millisecondsSinceEpoch,
        n.updatedAt.millisecondsSinceEpoch,
        n.version.encode(),
        n.lastDevice,
        n.deleted ? 1 : 0,
        n.important ? 1 : 0,
        n.archived ? 1 : 0,
        seq,
        src,
        jsonEncode(dismissed),
      ],
    );
  }

  List<String> _dismissed(String noteId) {
    final rs = _db.select('SELECT dismissed FROM notes WHERE id = ?', [noteId]);
    if (rs.isEmpty) return [];
    return (jsonDecode(rs.first['dismissed'] as String) as List).cast<String>();
  }

  Note createNote({String title = '', String content = emptyDeltaJson, String plainText = ''}) {
    final now = _now();
    final note = Note(
      id: _uuid.v4(),
      title: title,
      content: content,
      plainText: plainText,
      createdAt: now,
      updatedAt: now,
      version: VersionVector.empty.increment(deviceId),
      lastDevice: deviceId,
    );
    _tx(() {
      final seq = _appendLog(note.id, 'upsert', note.version, deviceId);
      _writeNote(note, seq, dismissed: const []);
    });
    _notify();
    return note;
  }

  /// Saves a local edit. Returns the updated note, or null if nothing changed.
  Note? updateNote(String id, {String? title, String? content, String? plainText}) {
    final result = _tx(() {
      final cur = getNote(id);
      if (cur == null) throw StateError('Note $id not found');
      final next = cur.copyWith(title: title, content: content, plainText: plainText);
      if (next.title == cur.title && next.content == cur.content && !cur.deleted) return null;
      final updated = next.copyWith(
        updatedAt: _now(),
        version: cur.version.increment(deviceId),
        lastDevice: deviceId,
        deleted: false,
      );
      final seq = _appendLog(id, 'upsert', updated.version, deviceId);
      _writeNote(updated, seq);
      return updated;
    });
    if (result != null) _notify();
    return result;
  }

  /// Marks a note as changed (new version) without touching its text, so the
  /// change is synced. Used when its attachments change.
  void touchNote(String id) {
    _tx(() {
      final cur = getNote(id);
      if (cur == null || cur.deleted) return;
      final next = cur.copyWith(
        updatedAt: _now(),
        version: cur.version.increment(deviceId),
        lastDevice: deviceId,
      );
      final seq = _appendLog(id, 'upsert', next.version, deviceId);
      _writeNote(next, seq);
    });
    _notify();
  }

  /// Soft delete (tombstone) so the deletion propagates to other devices.
  void deleteNotes(Iterable<String> ids) {
    _tx(() {
      for (final id in ids) {
        _deleteOne(id);
      }
    });
    _notify();
  }

  /// Soft delete (tombstone) so the deletion propagates to other devices.
  void deleteNote(String id) {
    _tx(() => _deleteOne(id));
    _notify();
  }

  void _deleteOne(String id) {
    final cur = getNote(id);
    if (cur == null || cur.deleted) return;
    final del = cur.copyWith(
      deleted: true,
      updatedAt: _now(),
      version: cur.version.increment(deviceId),
      lastDevice: deviceId,
    );
    final seq = _appendLog(id, 'delete', del.version, deviceId);
    _writeNote(del, seq);
    _db.execute('DELETE FROM attachments WHERE note_id = ?', [id]);
  }

  // ---------------------------------------------------------------- sync

  int get maxSeq =>
      (_db.select('SELECT COALESCE(MAX(seq), 0) AS m FROM notes').first['m'] as int);

  /// Random id of this database instance. If a peer reinstalls the app its
  /// epoch changes and cursors for it are reset.
  String get epoch {
    var e = getSetting('db_epoch');
    if (e == null) {
      e = _uuid.v4();
      setSetting('db_epoch', e);
    }
    return e;
  }

  /// Returns the receive cursor for [peerId], resetting it if the peer's
  /// database epoch changed.
  int recvCursorFor(String peerId, String peerEpoch) {
    final p = _db.select('SELECT epoch, recv_cursor FROM peers WHERE device_id = ?', [peerId]);
    if (p.isEmpty) return 0;
    if (p.first['epoch'] != peerEpoch) {
      _db.execute('UPDATE peers SET epoch = ?, recv_cursor = 0 WHERE device_id = ?', [peerEpoch, peerId]);
      // The peer lost its data: allow re-sending notes it originally sent us.
      _db.execute('UPDATE notes SET src = NULL WHERE src = ?', [peerId]);
      return 0;
    }
    return p.first['recv_cursor'] as int;
  }

  /// Notes changed after [afterSeq], ordered by seq. Only the latest state of
  /// each note is returned, so a note edited many times is sent once.
  /// Versions received from [excludeSrc] are skipped (no echo).
  /// Current position of the change log.
  int get logSeq =>
      (_db.select('SELECT COALESCE(MAX(seq), 0) AS m FROM change_log').first['m'] as int);

  /// Whether this device recorded a local edit after [seq].
  bool hasLocalChangeAfter(int seq) =>
      _db.select('SELECT 1 FROM change_log WHERE seq > ? AND device = ? LIMIT 1', [seq, deviceId]).isNotEmpty;

  ChangeBatch changesSince(int afterSeq, {int limit = 100, String? excludeSrc}) {
    final rs = _db.select(
      'SELECT $_noteCols, seq, src, dismissed FROM notes WHERE seq > ? ORDER BY seq LIMIT ?',
      [afterSeq, limit],
    );
    final items = <RemoteNote>[];
    var last = afterSeq;
    for (final r in rs) {
      last = r['seq'] as int;
      if (excludeSrc != null && r['src'] == excludeSrc) continue;
      final id = r['id'] as String;
      items.add(RemoteNote(
        _rowToNote(r).copyWith(hasConflict: false),
        dismissed: (jsonDecode(r['dismissed'] as String) as List).cast<String>(),
        conflicts: [for (final c in conflictsFor(id)) c.other],
        attachments: attachmentsFor(id),
      ));
    }
    return ChangeBatch(items, last, rs.length < limit);
  }

  /// Deterministic winner for concurrent versions: a live note beats a
  /// tombstone (no data loss), then later edit wins, then device id.
  static bool _remoteWins(Note local, Note remote) {
    if (local.deleted != remote.deleted) return local.deleted;
    final c = remote.updatedAt.compareTo(local.updatedAt);
    if (c != 0) return c > 0;
    return remote.lastDevice.compareTo(local.lastDevice) > 0;
  }

  static String conflictKey(Note n) => n.version.encode();

  /// Applies a batch received from [peerId] atomically together with the
  /// new receive cursor. If the process dies midway nothing is committed and
  /// the batch will simply be requested again.
  ApplyResult applyRemoteBatch(
    String peerId,
    List<RemoteNote> batch, {
    required int newCursor,
  }) {
    final result = ApplyResult();
    _tx(() {
      for (final rn in batch) {
        _applyOne(rn, result, peerId);
        _importRemoteConflicts(rn);
        _applyAttachments(rn);
      }
      _db.execute(
        'UPDATE peers SET recv_cursor = MAX(recv_cursor, ?) WHERE device_id = ?',
        [newCursor, peerId],
      );
    });
    if (result.applied > 0 || result.conflicts > 0) _notify();
    return result;
  }

  /// Imports attachment metadata of a received note. Only the metadata moves:
  /// the bytes stay on the device that added the file.
  void _applyAttachments(RemoteNote rn) {
    if (rn.note.deleted) {
      _db.execute('DELETE FROM attachments WHERE note_id = ?', [rn.note.id]);
      return;
    }
    if (getNote(rn.note.id) == null) return;
    // The remote list is the full set of attachments of that note version.
    _db.execute('DELETE FROM attachments WHERE note_id = ?', [rn.note.id]);
    for (final a in rn.attachments) {
      _db.execute(
        'INSERT OR IGNORE INTO attachments (id, note_id, name, mime, size, sha256, created) VALUES (?, ?, ?, ?, ?, ?, ?)',
        [a.id, rn.note.id, a.name, a.mime, a.size, a.sha256, a.createdAt.millisecondsSinceEpoch],
      );
    }
  }

  void _applyOne(RemoteNote rn, ApplyResult result, String peerId) {
    final remote = rn.note;
    final local = getNote(remote.id);
    final remoteDismissed = rn.dismissed;

    // Drop conflict copies the remote author already resolved.
    for (final key in remoteDismissed) {
      _db.execute('DELETE FROM conflicts WHERE note_id = ? AND loser_key = ?', [remote.id, key]);
    }

    if (local == null) {
      final seq = _appendLog(remote.id, remote.deleted ? 'delete' : 'upsert', remote.version, remote.lastDevice);
      _writeNote(remote, seq, dismissed: remoteDismissed, src: peerId);
      result.applied++;
      return;
    }

    final mergedDismissed = {..._dismissed(remote.id), ...remoteDismissed}.toList();
    if (mergedDismissed.length > 50) mergedDismissed.removeRange(0, mergedDismissed.length - 50);

    switch (local.version.compare(remote.version)) {
      case VvOrder.equal:
      case VvOrder.after:
        if (remoteDismissed.isNotEmpty) {
          _db.execute('UPDATE notes SET dismissed = ? WHERE id = ?', [jsonEncode(mergedDismissed), remote.id]);
        }
        result.ignored++;
        return;
      case VvOrder.before:
        final seq = _appendLog(remote.id, remote.deleted ? 'delete' : 'upsert', remote.version, remote.lastDevice);
        _writeNote(remote, seq, dismissed: mergedDismissed, src: peerId);
        result.applied++;
        return;
      case VvOrder.concurrent:
        final merged = local.version.merge(remote.version);
        final remoteWins = _remoteWins(local, remote);
        final winner = remoteWins ? remote : local;
        final loser = remoteWins ? local : remote;
        final keepLoser = !local.sameDataAs(remote) &&
            !loser.deleted &&
            !mergedDismissed.contains(conflictKey(loser));
        if (keepLoser) {
          _db.execute(
            'INSERT OR IGNORE INTO conflicts (note_id, loser_key, payload, detected) VALUES (?, ?, ?, ?)',
            [remote.id, conflictKey(loser), jsonEncode(loser.toWire()), _now().millisecondsSinceEpoch],
          );
          result.conflicts++;
        }
        final resolved = winner.copyWith(version: merged);
        final seq = _appendLog(remote.id, resolved.deleted ? 'delete' : 'merge', merged, winner.lastDevice);
        _writeNote(resolved, seq, dismissed: mergedDismissed);
        result.applied++;
    }
  }

  /// Imports alternative versions that the sender still keeps as conflicts,
  /// so that a conflict detected on one device is visible on all of them.
  void _importRemoteConflicts(RemoteNote rn) {
    if (rn.conflicts.isEmpty) return;
    final cur = getNote(rn.note.id);
    if (cur == null) return;
    final dismissed = _dismissed(rn.note.id);
    for (final alt in rn.conflicts) {
      final key = conflictKey(alt);
      if (dismissed.contains(key) || alt.sameDataAs(cur)) continue;
      _db.execute(
        'INSERT OR IGNORE INTO conflicts (note_id, loser_key, payload, detected) VALUES (?, ?, ?, ?)',
        [alt.id, key, jsonEncode(alt.toWire()), _now().millisecondsSinceEpoch],
      );
    }
  }

  // ---------------------------------------------------------------- attachments

  Attachment _rowToAttachment(Row r) => Attachment(
        id: r['id'] as String,
        noteId: r['note_id'] as String,
        name: r['name'] as String,
        mime: r['mime'] as String,
        size: r['size'] as int,
        sha256: r['sha256'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(r['created'] as int),
      );

  List<Attachment> attachmentsFor(String noteId) => _db
      .select('SELECT * FROM attachments WHERE note_id = ? ORDER BY created', [noteId])
      .map(_rowToAttachment)
      .toList();

  Attachment addAttachment({
    required String noteId,
    required String name,
    required String mime,
    required int size,
    required String sha256,
  }) {
    final a = Attachment(
      id: _uuid.v4(),
      noteId: noteId,
      name: name,
      mime: mime,
      size: size,
      sha256: sha256,
      createdAt: _now(),
    );
    _db.execute(
      'INSERT INTO attachments (id, note_id, name, mime, size, sha256, created) VALUES (?, ?, ?, ?, ?, ?, ?)',
      [a.id, a.noteId, a.name, a.mime, a.size, a.sha256, a.createdAt.millisecondsSinceEpoch],
    );
    touchNote(noteId);
    return a;
  }

  void removeAttachment(String id) {
    final row = _db.select('SELECT note_id FROM attachments WHERE id = ?', [id]);
    _db.execute('DELETE FROM attachments WHERE id = ?', [id]);
    if (row.isNotEmpty) touchNote(row.first['note_id'] as String);
  }

  Set<String> allAttachmentHashes() =>
      _db.select('SELECT DISTINCT sha256 FROM attachments').map((r) => r['sha256'] as String).toSet();

  /// Remembers where the user saved a copy of [sha256] (for "open location").
  void setSavedCopy(String sha256, String path) {
    _db.execute('INSERT OR REPLACE INTO saved_copies (sha256, path) VALUES (?, ?)', [sha256, path]);
  }

  String? savedCopyPath(String sha256) {
    final rs = _db.select('SELECT path FROM saved_copies WHERE sha256 = ?', [sha256]);
    return rs.isEmpty ? null : rs.first['path'] as String;
  }

  // ---------------------------------------------------------------- conflicts

  List<NoteConflict> conflictsFor(String noteId) => _db
      .select('SELECT * FROM conflicts WHERE note_id = ? ORDER BY detected', [noteId])
      .map(_rowToConflict)
      .toList();

  List<NoteConflict> allConflicts() =>
      _db.select('SELECT * FROM conflicts ORDER BY detected').map(_rowToConflict).toList();

  int get conflictCount => _db.select('SELECT COUNT(*) AS c FROM conflicts').first['c'] as int;

  NoteConflict _rowToConflict(Row r) => NoteConflict(
        id: r['id'] as int,
        noteId: r['note_id'] as String,
        other: Note.fromWire(jsonDecode(r['payload'] as String) as Map<String, dynamic>),
        detectedAt: DateTime.fromMillisecondsSinceEpoch(r['detected'] as int),
      );

  /// Resolves a conflict. The decision becomes a new version which, when
  /// synced, also removes the conflict copy on other devices.
  void resolveConflict(int conflictId, ConflictChoice choice) {
    _tx(() {
      final rs = _db.select('SELECT * FROM conflicts WHERE id = ?', [conflictId]);
      if (rs.isEmpty) return;
      final c = _rowToConflict(rs.first);
      final cur = getNote(c.noteId)!;
      final dismissed = {..._dismissed(c.noteId), conflictKey(c.other)}.toList();
      final version = cur.version.merge(c.other.version).increment(deviceId);
      final now = _now();
      var next = cur.copyWith(version: version, updatedAt: now, lastDevice: deviceId);
      if (choice == ConflictChoice.takeOther) {
        next = next.copyWith(
          title: c.other.title,
          content: c.other.content,
          plainText: c.other.plainText,
          deleted: false,
        );
      }
      final seq = _appendLog(c.noteId, 'resolve', version, deviceId);
      _writeNote(next, seq, dismissed: dismissed);
      _db.execute('DELETE FROM conflicts WHERE id = ?', [conflictId]);

      if (choice == ConflictChoice.keepBoth) {
        final copy = Note(
          id: _uuid.v4(),
          title: '${c.other.displayTitle} (копия конфликта)',
          content: c.other.content,
          plainText: c.other.plainText,
          createdAt: now,
          updatedAt: now,
          version: VersionVector.empty.increment(deviceId),
          lastDevice: deviceId,
        );
        final s2 = _appendLog(copy.id, 'upsert', copy.version, deviceId);
        _writeNote(copy, s2, dismissed: const []);
      }
    });
    _notify();
  }

  // ---------------------------------------------------------------- change log

  List<Map<String, Object?>> changeLog({int limit = 100}) => _db
      .select('SELECT * FROM change_log ORDER BY seq DESC LIMIT ?', [limit])
      .map((r) => Map<String, Object?>.from(r))
      .toList();

  /// Keeps the log bounded. Sync never relies on log rows (it uses note.seq),
  /// so pruning is safe.
  void pruneChangeLog({int keep = 5000}) {
    _db.execute(
      'DELETE FROM change_log WHERE seq <= (SELECT MAX(seq) FROM change_log) - ?',
      [keep],
    );
  }

  // ---------------------------------------------------------------- peers

  List<Peer> listPeers() =>
      _db.select('SELECT * FROM peers ORDER BY name').map(_rowToPeer).toList();

  Peer? getPeer(String deviceId) {
    final rs = _db.select('SELECT * FROM peers WHERE device_id = ?', [deviceId]);
    return rs.isEmpty ? null : _rowToPeer(rs.first);
  }

  Peer _rowToPeer(Row r) => Peer(
        deviceId: r['device_id'] as String,
        name: r['name'] as String,
        publicKey: base64Decode(r['public_key'] as String),
        pairedAt: DateTime.fromMillisecondsSinceEpoch(r['paired'] as int),
        lastSyncAt: r['last_sync'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(r['last_sync'] as int),
        lastAddress: r['addr'] as String?,
        lastPort: r['port'] as int?,
        recvCursor: r['recv_cursor'] as int,
      );

  void upsertPeer({
    required String deviceId,
    required String name,
    required List<int> publicKey,
  }) {
    _db.execute(
      'INSERT INTO peers (device_id, name, public_key, paired, recv_cursor) VALUES (?, ?, ?, ?, 0) '
      'ON CONFLICT(device_id) DO UPDATE SET name=excluded.name, public_key=excluded.public_key',
      [deviceId, name, base64Encode(publicKey), _now().millisecondsSinceEpoch],
    );
    _notify();
  }

  void updatePeerSeen(String deviceId, {String? address, int? port, bool synced = false}) {
    _db.execute(
      'UPDATE peers SET addr = COALESCE(?, addr), port = COALESCE(?, port)'
      '${synced ? ', last_sync = ${_now().millisecondsSinceEpoch}' : ''} WHERE device_id = ?',
      [address, port, deviceId],
    );
    if (synced) _notify();
  }

  void removePeer(String deviceId) {
    _db.execute('DELETE FROM peers WHERE device_id = ?', [deviceId]);
    _db.execute('DELETE FROM file_holders WHERE device_id = ?', [deviceId]);
    _notify();
  }

  /// Replaces the set of files that [deviceId] reports as stored locally.
  void setFileHolders(String deviceId, Iterable<String> hashes) {
    _tx(() {
      _db.execute('DELETE FROM file_holders WHERE device_id = ?', [deviceId]);
      for (final h in hashes) {
        _db.execute('INSERT OR IGNORE INTO file_holders (sha256, device_id) VALUES (?, ?)', [h, deviceId]);
      }
    });
    _notify();
  }

  /// Other paired devices that reported having the file [sha256].
  bool hasRemoteHolder(String sha256) =>
      _db.select('SELECT 1 FROM file_holders WHERE sha256 = ? LIMIT 1', [sha256]).isNotEmpty;

  // ---------------------------------------------------------------- settings

  String? getSetting(String key) {
    final rs = _db.select('SELECT value FROM settings WHERE key = ?', [key]);
    return rs.isEmpty ? null : rs.first['value'] as String?;
  }

  void setSetting(String key, String value) {
    _db.execute(
      'INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
      [key, value],
    );
  }
}

/// A page of outgoing changes. [lastSeq] is the cursor to acknowledge.
class ChangeBatch {
  final List<RemoteNote> notes;
  final int lastSeq;
  final bool done;
  const ChangeBatch(this.notes, this.lastSeq, this.done);
}

/// A note received over the wire plus conflict keys its author dismissed and
/// unresolved alternative versions the author still keeps.
class RemoteNote {
  final Note note;
  final List<String> dismissed;
  final List<Note> conflicts;
  final List<Attachment> attachments;
  const RemoteNote(
    this.note, {
    this.dismissed = const [],
    this.conflicts = const [],
    this.attachments = const [],
  });
}
