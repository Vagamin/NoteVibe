import '../../data/note_store.dart';
import '../../domain/attachment.dart';
import '../../domain/note.dart';
import '../crypto/secure_channel.dart';
import '../transport/frame_channel.dart';

class SyncStats {
  int sent = 0;
  int received = 0;
  int conflicts = 0;
  @override
  String toString() => 'SyncStats(sent=$sent, received=$received, conflicts=$conflicts)';
}

class SyncProtocolException implements Exception {
  final String message;
  SyncProtocolException(this.message);
  @override
  String toString() => 'SyncProtocolException: $message';
}

/// Runs one sync session over an authenticated [SecureChannel].
///
/// ```
/// I → R  start{epoch}
/// R → I  start{epoch}
/// R → I  want{cursor}          phase A: initiator pushes
/// I → R  batch{notes,last,done} … R → I ack{last}
/// I → R  want{cursor}          phase B: responder pushes
/// R → I  batch … I → R ack
/// I → R  bye
/// ```
///
/// The receiver owns the cursor and stores it in the same transaction as the
/// applied notes, so a dropped connection never loses or skips data: the next
/// session resumes from the last committed batch. Applying is idempotent.
class SyncEngine {
  final NoteStore store;
  final int batchSize;
  SyncEngine(this.store, {this.batchSize = 100});

  /// Runs a session. The channel is always closed afterwards.
  Future<SyncStats> run(SecureChannel ch, {required bool initiator}) async {
    try {
      return await _run(ch, initiator: initiator);
    } catch (e) {
      if (e is SyncProtocolException) {
        await ch.send({'t': 'error', 'msg': e.message}).catchError((_) {});
      }
      rethrow;
    } finally {
      await ch.close();
    }
  }

  Future<SyncStats> _run(SecureChannel ch, {required bool initiator}) async {
    final peerId = ch.remote.deviceId;
    if (store.getPeer(peerId) == null) {
      throw SyncProtocolException('peer $peerId is not paired');
    }
    final stats = SyncStats();
    String peerEpoch;
    if (initiator) {
      await ch.send({'t': 'start', 'epoch': store.epoch});
      peerEpoch = _expect(await ch.receive(), 'start')['epoch'] as String;
      await _push(ch, peerId, stats);
      await _pull(ch, peerId, peerEpoch, stats);
      await ch.send({'t': 'bye'});
    } else {
      peerEpoch = _expect(await ch.receive(), 'start')['epoch'] as String;
      await ch.send({'t': 'start', 'epoch': store.epoch});
      await _pull(ch, peerId, peerEpoch, stats);
      await _push(ch, peerId, stats);
      _expect(await ch.receive(), 'bye');
    }
    store.updatePeerSeen(peerId, synced: true);
    return stats;
  }

  Future<void> _push(SecureChannel ch, String peerId, SyncStats stats) async {
    var cursor = (_expect(await ch.receive(), 'want')['cursor'] as num).toInt();
    while (true) {
      final batch = store.changesSince(cursor, limit: batchSize, excludeSrc: peerId);
      await ch.send({
        't': 'batch',
        'notes': [
          for (final rn in batch.notes)
            {
              'n': rn.note.toWire(),
              'd': rn.dismissed,
              if (rn.conflicts.isNotEmpty) 'c': [for (final c in rn.conflicts) c.toWire()],
              'a': [for (final a in store.attachmentsFor(rn.note.id)) a.toWire()],
            }
        ],
        'last': batch.lastSeq,
        'done': batch.done,
      });
      final ack = _expect(await ch.receive(), 'ack');
      if ((ack['last'] as num).toInt() != batch.lastSeq) {
        throw SyncProtocolException('ack mismatch');
      }
      stats.sent += batch.notes.length;
      cursor = batch.lastSeq;
      if (batch.done) return;
    }
  }

  Future<void> _pull(SecureChannel ch, String peerId, String peerEpoch, SyncStats stats) async {
    final cursor = store.recvCursorFor(peerId, peerEpoch);
    await ch.send({'t': 'want', 'cursor': cursor});
    while (true) {
      final m = _expect(await ch.receive(), 'batch');
      final last = (m['last'] as num).toInt();
      final notes = <RemoteNote>[];
      for (final item in (m['notes'] as List)) {
        final map = item as Map<String, dynamic>;
        final note = Note.fromWire(map['n'] as Map<String, dynamic>);
        notes.add(RemoteNote(
          note,
          dismissed: ((map['d'] as List?) ?? const []).cast<String>(),
          conflicts: [
            for (final c in (map['c'] as List?) ?? const [])
              Note.fromWire(c as Map<String, dynamic>)
          ],
          attachments: [
            for (final a in (map['a'] as List?) ?? const [])
              Attachment.fromWire(a as Map<String, dynamic>, noteId: note.id)
          ],
        ));
      }
      final r = store.applyRemoteBatch(peerId, notes, newCursor: last);
      stats.received += r.applied;
      stats.conflicts += r.conflicts;
      await ch.send({'t': 'ack', 'last': last});
      if (m['done'] == true) return;
    }
  }

  static Map<String, dynamic> _expect(Map<String, dynamic> m, String type) {
    if (m['t'] == 'error') throw SyncProtocolException('remote error: ${m['msg']}');
    if (m['t'] != type) throw SyncProtocolException('expected $type, got ${m['t']}');
    return m;
  }
}

/// Convenience: true for errors caused by the network rather than bugs.
bool isNetworkError(Object e) => e is TransportException || e is HandshakeException;
