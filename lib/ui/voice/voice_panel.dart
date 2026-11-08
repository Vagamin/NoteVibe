import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/note_store.dart';
import '../../domain/attachment.dart';
import '../attachments/attachment_service.dart';
import '../attachments/attachments_panel.dart';
import '../providers.dart';
import '../select_dot.dart';
import 'voice_player.dart';
import 'voice_service.dart';

final voiceServiceProvider = Provider<VoiceService>((ref) {
  final s = ref.watch(servicesProvider);
  final svc = VoiceService(s.store, s.attachments);
  s.lockHandlers.add(svc.cancel);
  ref.onDispose(() { s.lockHandlers.remove(svc.cancel); svc.dispose(); });
  return svc;
});

/// Recordings of a voice note: record, stop, play, delete.
/// Recordings are attachments, so they sync like any file.
class VoicePanel extends ConsumerStatefulWidget {
  final String noteId;
  const VoicePanel({super.key, required this.noteId});

  @override
  ConsumerState<VoicePanel> createState() => _VoicePanelState();
}

class _VoicePanelState extends ConsumerState<VoicePanel> {
  bool _recording = false;
  bool _selecting = false;
  final Set<String> _selected = {};
  DateTime? _startedAt;
  Timer? _tick;
  Timer? _limit;
  Duration _elapsed = Duration.zero;

  @override
  void dispose() {
    _tick?.cancel();
    _limit?.cancel();
    if (_recording) ref.read(voiceServiceProvider).cancel();
    super.dispose();
  }

  Future<void> _start(int count) async {
    final messenger = ScaffoldMessenger.of(context);
    if (count >= maxVoiceRecordings) {
      messenger.showSnackBar(const SnackBar(content: Text('В заметке уже $maxVoiceRecordings записей')));
      return;
    }
    try {
      final device = ref.read(captureDeviceProvider);
      final ok = await ref.read(voiceServiceProvider).start(deviceId: device.isEmpty ? null : device);
      if (!ok) {
        messenger.showSnackBar(const SnackBar(content: Text('Нет доступа к микрофону')));
        return;
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Не удалось начать запись: $e')));
      return;
    }
    _startedAt = DateTime.now();
    _elapsed = Duration.zero;
    setState(() => _recording = true);
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _elapsed = DateTime.now().difference(_startedAt!));
    });
    _limit = Timer(maxVoiceDuration, _stop);
  }

  Future<void> _stop() async {
    _tick?.cancel();
    _limit?.cancel();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _recording = false);
    try {
      final saved = await ref.read(voiceServiceProvider).stopAndAttach(widget.noteId);
      if (!saved) messenger.showSnackBar(const SnackBar(content: Text('Запись пустая, ничего не сохранено')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Не удалось сохранить запись: $e')));
    }
  }

  Future<void> _cancel() async {
    _tick?.cancel();
    _limit?.cancel();
    setState(() => _recording = false);
    await ref.read(voiceServiceProvider).cancel();
  }

  Future<void> _saveSelected(List<Attachment> items, AttachmentService svc) async {
    if (ref.read(servicesProvider).vault != null) {
      final allowed = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
        title: const Text('Сохранить записи без шифрования?'),
        content: const Text('Экспортированные записи будут доступны без пароля приложения и не удалятся при его закрытии.'),
        actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Сохранить копии'))],
      ));
      if (allowed != true || !mounted) return;
    }
    final chosen = _selected.isEmpty ? items : items.where((a) => _selected.contains(a.id)).toList();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final n = await svc.saveRecordings(chosen);
      if (n > 0) messenger.showSnackBar(SnackBar(content: Text('Сохранено записей: $n')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Не удалось сохранить: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    ref.watch(storeChangesProvider);
    final store = ref.watch(storeProvider);
    final svc = ref.watch(attachmentServiceProvider);
    final items = store.attachmentsFor(widget.noteId).where((a) => a.mime.startsWith('audio/')).toList();
    final count = items.length;
    final mobile = Platform.isAndroid;
    _selected.retainAll(items.map((a) => a.id));
    final showSelection = !mobile || _selecting;

    final recordButton = FilledButton.icon(
      onPressed: count >= maxVoiceRecordings ? null : () => _start(count),
      icon: const Icon(Icons.mic),
      label: Text(count == 0 ? 'Записать' : 'Записать ещё'),
    );

    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selecting) setState(() { _selecting = false; _selected.clear(); });
      },
      child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).cardTheme.color,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Icon(Icons.mic, color: scheme.primary, size: 18),
            const SizedBox(width: 6),
            Expanded(child: Text('Записи', style: Theme.of(context).textTheme.titleSmall)),
            if (mobile && _selecting)
              IconButton(
                tooltip: 'Отменить выбор записей',
                icon: const Icon(Icons.close),
                onPressed: () => setState(() {
                  _selecting = false;
                  _selected.clear();
                }),
              ),
            Text('$count из $maxVoiceRecordings', style: TextStyle(color: scheme.outline)),
          ]),
          const SizedBox(height: 6),
          if (_recording)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.errorContainer,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                Icon(Icons.fiber_manual_record, color: scheme.error, size: 18),
                const SizedBox(width: 8),
                Text(_format(_elapsed), style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
                const SizedBox(width: 10),
                const Expanded(child: Text('Идёт запись')),
                ]),
                const SizedBox(height: 8),
                RecordingWave(
                    service: ref.read(voiceServiceProvider),
                    color: scheme.error,
                ),
                const SizedBox(height: 8),
                Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: [
                TextButton(onPressed: _cancel, child: const Text('Отмена')),
                FilledButton.icon(
                  onPressed: _stop,
                  icon: const Icon(Icons.stop),
                  label: const Text('Стоп'),
                ),
                ]),
              ]),
            )
          else if (!mobile)
            recordButton,
          AnimatedSize(
            duration: const Duration(milliseconds: 280),
            reverseDuration: const Duration(milliseconds: 220),
            curve: Curves.easeInOutCubic,
            alignment: Alignment.topCenter,
            child: items.isNotEmpty && showSelection ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: () => _saveSelected(items, svc),
              icon: const Icon(Icons.save_alt),
              label: Text(_selected.isEmpty ? 'Сохранить все' : 'Сохранить выбранное (${_selected.length})'),
            ),
              ],
            ) : const SizedBox(width: double.infinity),
          ),
          const SizedBox(height: 6),
          if (items.isEmpty && !_recording)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text('Записей пока нет. Одна запись до 5 минут.', style: TextStyle(color: scheme.outline)),
            ),
          for (final a in items)
            _RecordingTile(
              attachment: a,
              svc: svc,
              store: store,
              showSelection: showSelection,
              checked: _selected.contains(a.id),
              onLongPress: mobile ? () => setState(() {
                _selecting = true;
                _selected.add(a.id);
              }) : null,
              onToggle: () => setState(() => _selected.contains(a.id) ? _selected.remove(a.id) : _selected.add(a.id)),
            ),
          if (mobile && !_recording) ...[
            const SizedBox(height: 8),
            recordButton,
          ],
        ],
      ),
    ));
  }

  static String _format(Duration d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.inMinutes)}:${two(d.inSeconds % 60)}';
  }
}

class _RecordingTile extends ConsumerWidget {
  final Attachment attachment;
  final AttachmentService svc;
  final NoteStore store;
  final bool checked;
  final bool showSelection;
  final VoidCallback? onLongPress;
  final VoidCallback onToggle;
  const _RecordingTile({
    required this.attachment,
    required this.svc,
    required this.store,
    required this.checked,
    required this.showSelection,
    this.onLongPress,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final remoteHeld = store.hasRemoteHolder(attachment.sha256);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        onLongPress: onLongPress,
        onTap: showSelection && Platform.isAndroid ? onToggle : null,
        behavior: HitTestBehavior.opaque,
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        _SelectionReveal(visible: showSelection, child: Row(mainAxisSize: MainAxisSize.min, children: [
        InkResponse(
          onTap: onToggle,
          radius: 18,
          highlightColor: Colors.transparent,
          splashColor: Colors.transparent,
          hoverColor: Colors.transparent,
          focusColor: Colors.transparent,
          child: SizedBox(
            width: 36,
            height: 36,
            child: Center(child: SelectDot(checked: checked)),
          ),
        ),
        const SizedBox(width: 6),
        ])),
        Expanded(
          child: IgnorePointer(
            ignoring: showSelection && Platform.isAndroid,
            child: VoicePlayer(
            attachment: attachment,
            svc: svc,
            remoteHeld: remoteHeld,
            onDownload: () => svc.download(attachment),
          ),
          ),
        ),
        _SelectionReveal(visible: showSelection, child: Row(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(width: 8),
        IconButton(
          tooltip: 'Удалить запись',
          icon: const Icon(Icons.delete_outline),
          onPressed: () => _confirmDelete(context),
        ),
        ])),
      ]),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Удалить запись?'),
        content: Text(attachment.name),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Удалить')),
        ],
      ),
    );
    if (ok == true) svc.remove(attachment);
  }
}

/// Keeps controls mounted while smoothly revealing their occupied width.
class _SelectionReveal extends StatelessWidget {
  final bool visible;
  final Widget child;
  const _SelectionReveal({required this.visible, required this.child});

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !visible,
    child: ClipRect(
      child: AnimatedAlign(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeInOutCubic,
        alignment: Alignment.center,
        widthFactor: visible ? 1 : 0,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 220),
          opacity: visible ? 1 : 0,
          child: child,
        ),
      ),
    ),
  );
}
