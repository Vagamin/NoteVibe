import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../domain/attachment.dart';
import '../attachments/attachment_service.dart';
import 'voice_service.dart';

/// Id of the recording that plays now. Starting one pauses the others.
class ActiveVoiceNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? id) => state = id;
}

final activeVoiceProvider = NotifierProvider<ActiveVoiceNotifier, String?>(ActiveVoiceNotifier.new);

/// One recording as a chat-style bubble: play button, waveform, duration.
/// [compact] is the smaller form used on note cards in the list.
class VoicePlayer extends ConsumerStatefulWidget {
  final Attachment attachment;
  final AttachmentService svc;
  final bool remoteHeld;
  final VoidCallback? onDownload;
  final bool compact;

  const VoicePlayer({
    super.key,
    required this.attachment,
    required this.svc,
    required this.remoteHeld,
    this.onDownload,
    this.compact = false,
  });

  @override
  ConsumerState<VoicePlayer> createState() => _VoicePlayerState();
}

class _VoicePlayerState extends ConsumerState<VoicePlayer> with SingleTickerProviderStateMixin {
  final _player = AudioPlayer();
  final _subs = <StreamSubscription<Object?>>[];
  late final AnimationController _wave = AnimationController(vsync: this, duration: const Duration(milliseconds: 3600));
  bool _playing = false;
  Duration _pos = Duration.zero;
  Duration _len = Duration.zero;
  String? _path;
  String? _error;

  @override
  void initState() {
    super.initState();
    _subs.add(_player.playerStateStream.listen((s) {
      if (!mounted) return;
      final done = s.processingState == ProcessingState.completed;
      setState(() {
        _playing = s.playing && !done;
        if (done) _pos = Duration.zero;
      });
      // Loading -> buffering -> ready can emit several playing states. Do not
      // restart the ticker on each event, or the waveform stutters at startup.
      final animate = _playing && s.processingState == ProcessingState.ready;
      if (animate && !_wave.isAnimating) {
        _wave.repeat();
      } else if (!animate && _wave.isAnimating) {
        _wave.stop();
      }
    }));
    _subs.add(_player.positionStream.listen((p) {
      if (mounted) setState(() => _pos = p);
    }));
    _subs.add(_player.durationStream.listen((d) {
      if (mounted && d != null) setState(() => _len = d);
    }));
    _loadDuration();
  }

  /// Reads the length once so the time shows before the first play.
  Future<void> _loadDuration() async {
    if (!widget.svc.files.has(widget.attachment.sha256)) return;
    try {
      _path ??= await widget.svc.playablePath(widget.attachment);
      await _player.setFilePath(_path!);
    } catch (_) {
      // Length stays unknown; playing the recording still reports the error.
    }
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _wave.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_playing) {
      await _player.pause();
      return;
    }
    try {
      _path ??= await widget.svc.playablePath(widget.attachment);
      ref.read(activeVoiceProvider.notifier).set(widget.attachment.id);
      if (_player.audioSource == null) {
        await _player.setFilePath(_path!);
      }
      if (_player.processingState == ProcessingState.completed) {
        await _player.seek(Duration.zero);
      }
      await _player.play();
      if (mounted) setState(() => _error = null);
    } catch (e) {
      if (mounted) setState(() => _error = 'Не удалось воспроизвести: $e');
    }
  }

  Future<void> _seek(double fraction) async {
    if (_len.inMilliseconds == 0) return;
    await _player.seek(Duration(milliseconds: (_len.inMilliseconds * fraction.clamp(0.0, 1.0)).round()));
  }


  static String _fmt(Duration d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.inMinutes)}:${two(d.inSeconds % 60)}';
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String?>(activeVoiceProvider, (prev, next) {
      if (next != widget.attachment.id && _playing) _player.pause();
    });
    final scheme = Theme.of(context).colorScheme;
    final a = widget.attachment;
    final present = widget.svc.files.has(a.sha256);
    final total = _len.inMilliseconds == 0 ? 1 : _len.inMilliseconds;
    final progress = (_pos.inMilliseconds / total).clamp(0.0, 1.0).toDouble();
    final compact = widget.compact;
    final buttonSize = compact ? 32.0 : 40.0;
    final waveHeight = buttonSize;

    final button = Material(
      color: present ? scheme.primary : scheme.outlineVariant,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: present ? _toggle : (widget.remoteHeld ? widget.onDownload : null),
        child: SizedBox(
          width: buttonSize,
          height: buttonSize,
          child: Icon(
            !present
                ? (widget.remoteHeld ? Icons.download : Icons.error_outline)
                : (_playing ? Icons.pause : Icons.play_arrow),
            color: scheme.onPrimary,
            size: compact ? 20 : 24,
          ),
        ),
      ),
    );

    final wave = LayoutBuilder(
      builder: (context, c) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: present ? (d) => _seek(d.localPosition.dx / c.maxWidth) : null,
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: progress),
          duration: const Duration(milliseconds: 180),
          curve: Curves.linear,
          builder: (context, displayedProgress, _) => AnimatedBuilder(
          animation: _wave,
          builder: (context, _) => CustomPaint(
            size: Size(c.maxWidth, waveHeight),
            painter: _WavePainter(
              seed: a.sha256,
              phase: _wave.value,
              progress: displayedProgress,
              playing: _playing,
              active: scheme.primary,
              idle: scheme.outline.withValues(alpha: 0.4),
            ),
          ),
          ),
        ),
      ),
    );

    final caption = !present
        ? (widget.remoteHeld ? 'На другом устройстве' : 'Нет на устройстве')
        : '${_fmt(_pos)} / ${_fmt(_len)}';

    final timeText = Text(
      _error ?? caption,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.visible,
      textAlign: TextAlign.right,
      style: TextStyle(
        color: _error != null || !present ? scheme.error : scheme.outline,
        fontSize: compact ? 10.5 : 11,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );

    final timeBox = Align(alignment: Alignment.centerRight, child: timeText);

    final row = Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      button,
      SizedBox(width: compact ? 8 : 12),
      Expanded(child: wave),
      SizedBox(width: compact ? 8 : 12),
      timeBox,
    ]);

    if (compact) return row;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(22),
      ),
      child: row,
    );
  }
}

/// Rounded bars shaped by the file hash. Bars move while playing, with a
/// different rhythm per bar. The played part is coloured.
class _WavePainter extends CustomPainter {
  final String seed;
  final double phase;
  final double progress;
  final bool playing;
  final Color active;
  final Color idle;

  _WavePainter({
    required this.seed,
    required this.phase,
    required this.progress,
    required this.playing,
    required this.active,
    required this.idle,
  });

  static const _barWidth = 3.0;
  static const _gap = 2.0;

  @override
  void paint(Canvas canvas, Size size) {
    final count = math.max(1, (size.width / (_barWidth + _gap)).floor());
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = _barWidth;
    final s = seed.isEmpty ? '0' : seed;
    final mid = size.height / 2;
    final step = size.width / count;
    for (var i = 0; i < count; i++) {
      final code = s.codeUnitAt((i * 7) % s.length);
      final base = 0.25 + 0.75 * ((code % 13) / 12);
       // Integer frequencies make the repeat boundary seamless. Keep the
       // current phase on pause instead of snapping back to full-height bars.
       final angle = phase * 2 * math.pi;
       final wave = 0.82 +
           0.12 * math.sin(angle + i * 0.45) +
           0.06 * math.sin(2 * angle - i * 0.3);
      final h = math.max(3.0, size.height * base * wave);
      final x = step * i + step / 2;
       // Blend across each bar instead of abruptly switching its entire colour
       // when a position update crosses it (especially visible on bars 1–2).
       final coverage = (progress * count - i).clamp(0.0, 1.0);
       paint.color = Color.lerp(idle, active, coverage)!;
      canvas.drawLine(Offset(x, mid - h / 2), Offset(x, mid + h / 2), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) =>
      old.phase != phase ||
      old.progress != progress ||
      old.playing != playing ||
      old.seed != seed ||
      old.active != active ||
      old.idle != idle;
}

/// Live bars shown while recording: the newest level enters on the right and
/// older ones move left, so the row looks like the voice is being drawn.
/// Bars shown while recording. The painter redraws on every audio chunk, so the
/// bars move with the voice.
class RecordingWave extends StatelessWidget {
  final VoiceService service;
  final Color color;

  const RecordingWave({super.key, required this.service, required this.color});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(double.infinity, 28),
      painter: _LevelPainter(service: service, color: color),
    );
  }
}

class _LevelPainter extends CustomPainter {
  final VoiceService service;
  final Color color;

  _LevelPainter({required this.service, required this.color}) : super(repaint: service.chunks);

  @override
  void paint(Canvas canvas, Size size) {
    final values = service.history;
    final n = values.length;
    final step = size.width / n;
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = math.min(3.0, step * 0.6)
      ..color = color;
    final mid = size.height / 2;
    for (var i = 0; i < n; i++) {
      final h = math.max(3.0, size.height * values[i]);
      final x = step * i + step / 2;
      canvas.drawLine(Offset(x, mid - h / 2), Offset(x, mid + h / 2), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _LevelPainter old) => old.color != color;
}
