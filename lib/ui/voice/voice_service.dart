import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

import '../../data/attachment_storage.dart';
import '../../data/note_store.dart';

/// A voice note holds up to this many recordings.
const maxVoiceRecordings = 5;

/// Each recording stops by itself after this long.
const maxVoiceDuration = Duration(minutes: 5);

/// Speech quality, mono 16-bit PCM. About 32 KB per second.
const _sampleRate = 16000;

/// Records voice notes. The microphone is read as a PCM stream, so the live
/// level comes from the real samples on every platform. The stream is wrapped
/// in a WAV container and stored as an ordinary attachment, so it syncs,
/// verifies and downloads like any file.
class VoiceService {
  final NoteStore store;
  final AttachmentStorage files;
  final AudioRecorder _recorder = AudioRecorder();

  /// Recent input levels 0..1, one per audio chunk. The bars draw this list.
  final List<double> history = List.filled(48, 0.0, growable: true);

  /// Counts audio chunks. Notifies on every chunk, so the bars redraw with the sound.
  final ValueNotifier<int> chunks = ValueNotifier(0);

  bool _recording = false;
  BytesBuilder? _pcm;
  StreamSubscription<Uint8List>? _sub;
  Completer<void>? _done;

  VoiceService(this.store, this.files);

  bool get recording => _recording;

  /// Starts recording. [deviceId] picks the microphone (null = system default).
  Future<bool> start({String? deviceId}) async {
    if (!await _recorder.hasPermission()) return false;
    InputDevice? device;
    if (deviceId != null) {
      final devices = await _recorder.listInputDevices();
      device = devices.where((d) => d.id == deviceId).firstOrNull;
    }
    final stream = await _recorder.startStream(
      RecordConfig(encoder: AudioEncoder.pcm16bits, sampleRate: _sampleRate, numChannels: 1, device: device),
    );
    final pcm = BytesBuilder(copy: false);
    final done = Completer<void>();
    _pcm = pcm;
    _done = done;
    _recording = true;
    _sub = stream.listen(
      (chunk) {
        pcm.add(chunk);
        history
          ..removeAt(0)
          ..add(_levelOf(chunk));
        chunks.value = chunks.value + 1;
      },
      onDone: () => done.complete(),
      onError: (Object _) => done.complete(),
    );
    return true;
  }

  /// Stops recording and attaches the result to [noteId]. Returns false when
  /// nothing was recorded.
  Future<bool> stopAndAttach(String noteId) async {
    if (!_recording) return false;
    await _recorder.stop();
    await _finishStream();
    final pcm = _pcm?.takeBytes() ?? Uint8List(0);
    _pcm = null;
    _resetLevels();
    if (pcm.isEmpty) return false;
    final bytes = _wav(pcm);
    final hash = await files.save(bytes);
    store.addAttachment(
      noteId: noteId,
      name: 'Голос ${_stamp()}.wav',
      mime: voiceMime,
      size: bytes.length,
      sha256: hash,
    );
    return true;
  }

  /// Drops the current recording without saving it.
  Future<void> cancel() async {
    if (!_recording) return;
    await _recorder.cancel();
    await _finishStream();
    _pcm = null;
    _resetLevels();
  }

  void _resetLevels() {
    history.fillRange(0, history.length, 0.0);
    chunks.value = 0;
  }

  /// Waits for the stream to close after stop/cancel, so every chunk is in.
  Future<void> _finishStream() async {
    try {
      await _done?.future.timeout(const Duration(seconds: 3));
    } catch (_) {
      // A stalled stream just ends with the data received so far.
    }
    await _sub?.cancel();
    _sub = null;
    _done = null;
    _recording = false;
  }

  /// Microphones the system offers. Empty when the platform cannot list them.
  Future<List<InputDevice>> inputDevices() async {
    try {
      return await _recorder.listInputDevices();
    } catch (_) {
      return const [];
    }
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    chunks.dispose();
    await _recorder.dispose();
  }

  /// Loudness of one PCM chunk: peak sample in dBFS (-55..-15) mapped to 0..1.
  static double _levelOf(Uint8List chunk) {
    final data = ByteData.sublistView(chunk);
    final n = chunk.length ~/ 2;
    if (n == 0) return 0;
    var peak = 0;
    for (var i = 0; i < n; i++) {
      final s = data.getInt16(i * 2, Endian.little).abs();
      if (s > peak) peak = s;
    }
    if (peak == 0) return 0;
    final db = 20 * math.log(peak / 32768) / math.ln10;
    return ((db + 55) / 40).clamp(0.0, 1.0).toDouble();
  }

  /// Wraps raw 16-bit mono PCM in a WAV header.
  static Uint8List _wav(Uint8List pcm) {
    final h = ByteData(44);
    void text(int offset, String t) {
      for (var i = 0; i < 4; i++) {
        h.setUint8(offset + i, t.codeUnitAt(i));
      }
    }

    text(0, 'RIFF');
    h.setUint32(4, 36 + pcm.length, Endian.little);
    text(8, 'WAVE');
    text(12, 'fmt ');
    h.setUint32(16, 16, Endian.little);
    h.setUint16(20, 1, Endian.little);
    h.setUint16(22, 1, Endian.little);
    h.setUint32(24, _sampleRate, Endian.little);
    h.setUint32(28, _sampleRate * 2, Endian.little);
    h.setUint16(32, 2, Endian.little);
    h.setUint16(34, 16, Endian.little);
    text(36, 'data');
    h.setUint32(40, pcm.length, Endian.little);
    return (BytesBuilder(copy: false)..add(h.buffer.asUint8List())..add(pcm)).toBytes();
  }

  /// Recordings are WAV on every platform.
  static const voiceMime = 'audio/wav';

  static String _stamp() {
    final d = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}.${two(d.minute)}.${two(d.second)}';
  }
}
