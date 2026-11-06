import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/attachment.dart';
import '../providers.dart';
import '../select_dot.dart';
import 'attachment_service.dart';
import '../voice/voice_player.dart';

final attachmentServiceProvider = Provider<AttachmentService>((ref) {
  final s = ref.watch(servicesProvider);
  return AttachmentService(s.store, s.attachments, s.sync);
});

/// Ids of attachments being downloaded right now.
class DownloadingNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => <String>{};

  void add(String id) => state = {...state, id};
  void remove(String id) => state = {...state}..remove(id);
}

final downloadingProvider = NotifierProvider<DownloadingNotifier, Set<String>>(DownloadingNotifier.new);

Future<void> addNoteAttachments(BuildContext context, WidgetRef ref, String noteId) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    if (Platform.isAndroid) {
      final source = await showModalBottomSheet<String>(context: context, builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.photo_library_outlined), title: const Text('Фото из галереи'),
            onTap: () => Navigator.pop(c, 'gallery')),
          ListTile(leading: const Icon(Icons.attach_file), title: const Text('Выбрать файлы'),
            onTap: () => Navigator.pop(c, 'files')),
        ]),
      ));
      if (source == null) return;
      if (source == 'gallery') {
        await ref.read(attachmentServiceProvider).pickPhoto(noteId);
        return;
      }
    }
    final result = await ref.read(attachmentServiceProvider).pickAndAttach(noteId);
    if (result.failed.isNotEmpty) {
      messenger.showSnackBar(SnackBar(content: Text(result.failed.join('\n'))));
    }
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Не удалось добавить файл: $e')));
  }
}

/// Attachments of one note: add, open, download, save a copy, delete.
///
/// Status dot: green = file is on this device, grey = file is missing here.
/// Grey files can be downloaded from another paired device.
class AttachmentsPanel extends ConsumerStatefulWidget {
  final String noteId;
  /// Hides audio files; voice notes show their recordings in their own panel.
  final bool skipAudio;
  const AttachmentsPanel({super.key, required this.noteId, this.skipAudio = false});

  @override
  ConsumerState<AttachmentsPanel> createState() => _AttachmentsPanelState();
}

class _AttachmentsPanelState extends ConsumerState<AttachmentsPanel> {
  Set<String>? _selected;

  void _toggle(String id) {
    final s = {...?_selected};
    if (!s.remove(id)) s.add(id);
    setState(() => _selected = s);
  }

  Future<void> _bulkDelete(AttachmentService svc, List<Attachment> all) async {
    final chosen = all.where((a) => _selected?.contains(a.id) ?? false).toList();
    if (chosen.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Удалить вложения (${chosen.length})?'),
        content: Text(chosen.map((a) => a.name).join('\n')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Удалить')),
        ],
      ),
    );
    if (ok != true) return;
    for (final a in chosen) {
      svc.remove(a);
    }
    setState(() => _selected = null);
  }

  @override
  Widget build(BuildContext context) {
    final noteId = widget.noteId;
    final store = ref.watch(storeProvider);
    final svc = ref.watch(attachmentServiceProvider);
    // Rebuild when attachments or notes change.
    ref.watch(storeChangesProvider);
    final busy = ref.watch(downloadingProvider);
    final items = store.attachmentsFor(noteId).where((a) => !(widget.skipAudio && a.mime.startsWith('audio/'))).toList();
    final selecting = _selected != null;
    if (items.isEmpty) return const SizedBox.shrink();

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          Expanded(child: Text('Вложения · ${items.length}', style: Theme.of(context).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600))),
          if (items.isNotEmpty && !selecting)
            IconButton(
              tooltip: 'Выбрать вложения',
              onPressed: () => setState(() => _selected = {}),
              icon: const Icon(Icons.checklist_outlined),
            ),
          if (selecting)
            TextButton(
              onPressed: () => setState(() => _selected = null),
              child: const Text('Готово'),
            ),
          if (!selecting)
            IconButton(
              tooltip: 'Добавить вложения',
              onPressed: () => _add(context, svc),
              icon: const Icon(Icons.add, size: 20),
            ),
        ]),
        if (selecting)
          Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, children: [
            Text('Выбрано: ${_selected!.length}'),
            TextButton.icon(
              onPressed: _selected!.isEmpty ? null : () => _bulkDelete(svc, items),
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Удалить выбранные'),
            ),
          ]),
        for (final a in items)
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _AttachmentTile(
            attachment: a,
            present: svc.files.has(a.sha256),
            remoteHeld: store.hasRemoteHolder(a.sha256),
            hasSavedCopy: svc.savedPath(a) != null,
            downloading: busy.contains(a.id),
            checked: selecting ? _selected!.contains(a.id) : null,
            onOpen: () => _run(context, () => svc.open(a)),
            onDownload: () => _download(context, svc, a),
            onFreeSpace: () => _run(context, () => svc.freeSpace(a)),
            onSave: () => _saveCopy(context, svc, a),
            onCopy: () => _copyToClipboard(context, svc, a),
            onLocation: () => _run(context, () => svc.openLocation(a)),
            onDelete: () => _confirmRemove(context, svc, a),
            onTapSelect: selecting ? () => _toggle(a.id) : null,
            preview: a.isImage && svc.files.has(a.sha256) ? _VerifiedThumbnail(attachment: a, service: svc) : null,
            onRename: store.getSetting('attachment_rename') == 'true' ? () => _rename(a) : null,
          ),
          if (a.mime.startsWith('audio/') && !selecting)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: VoicePlayer(attachment: a, svc: svc, remoteHeld: store.hasRemoteHolder(a.sha256), onDownload: () => _download(context, svc, a)),
            ),
          ]),
      ],
        ),
      ),
    );
  }

  Future<void> _rename(Attachment a) async {
    final controller = TextEditingController(text: a.label);
    final value = await showDialog<String>(context: context, builder: (c) => AlertDialog(
      title: const Text('Название в приложении'),
      content: TextField(controller: controller, autofocus: true, maxLength: 200,
        decoration: InputDecoration(hintText: a.name, helperText: 'Оригинальный файл не переименовывается'),
        onSubmitted: (v) => Navigator.pop(c, v)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Отмена')),
        TextButton(onPressed: () => Navigator.pop(c, ''), child: const Text('Сбросить')),
        FilledButton(onPressed: () => Navigator.pop(c, controller.text), child: const Text('Сохранить')),
      ],
    ));
    if (value != null && mounted) {
      await _run(context, () async => ref.read(storeProvider).renameAttachment(a.id, value));
    }
    // Dialog route finishes its exit animation before releasing its controller.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    controller.dispose();
  }

  Future<void> _download(BuildContext context, AttachmentService svc, Attachment a) async {
    final messenger = ScaffoldMessenger.of(context);
    final downloads = ref.read(downloadingProvider.notifier);
    downloads.add(a.id);
    try {
      await svc.download(a);
      messenger.showSnackBar(SnackBar(content: Text('Загружено: ${a.name}')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      downloads.remove(a.id);
    }
  }

  Future<void> _add(BuildContext context, AttachmentService svc) async {
    await addNoteAttachments(context, ref, widget.noteId);
  }

  Future<void> _run(BuildContext context, Future<void> Function() action) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _saveCopy(BuildContext context, AttachmentService svc, Attachment a) async {
    if (ref.read(servicesProvider).vault != null) {
      final allowed = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
        title: const Text('Сохранить без шифрования?'),
        content: const Text('Экспортированная копия будет доступна без пароля приложения и не удалится при его закрытии.'),
        actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Сохранить копию'))],
      ));
      if (allowed != true || !context.mounted) return;
    }
    final messenger = ScaffoldMessenger.of(context);
    try {
      final path = await svc.saveCopy(a);
      if (path != null) {
        messenger.showSnackBar(SnackBar(content: Text('Сохранено: $path')));
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _copyToClipboard(BuildContext context, AttachmentService svc, Attachment a) async {
    if (ref.read(servicesProvider).vault != null) {
      final allowed = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
        title: const Text('Копировать без шифрования?'),
        content: const Text('Другие приложения получат доступ к файлу через буфер обмена. Открытая временная копия останется до очистки кэша.'),
        actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Копировать'))],
      ));
      if (allowed != true || !context.mounted) return;
    }
    final messenger = ScaffoldMessenger.of(context);
    try {
      await svc.copyToClipboard(a);
      messenger.showSnackBar(const SnackBar(content: Text('Файл скопирован в буфер обмена')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Не удалось скопировать файл: $e')));
    }
  }

  Future<void> _confirmRemove(BuildContext context, AttachmentService svc, Attachment a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Удалить вложение?'),
        content: Text(a.name),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Удалить')),
        ],
      ),
    );
    if (ok == true) svc.remove(a);
  }
}

class _VerifiedThumbnail extends StatefulWidget {
  final Attachment attachment;
  final AttachmentService service;
  const _VerifiedThumbnail({required this.attachment, required this.service});
  @override
  State<_VerifiedThumbnail> createState() => _VerifiedThumbnailState();
}

class _VerifiedThumbnailState extends State<_VerifiedThumbnail> {
  late final _bytes = widget.service.files.readVerified(widget.attachment.sha256, size: widget.attachment.size);
  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _bytes,
    builder: (context, snapshot) => snapshot.hasData
      ? Image.memory(snapshot.data!, width: 40, height: 40, cacheWidth: 120, fit: BoxFit.cover,
          errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined))
      : Icon(snapshot.hasError ? Icons.broken_image_outlined : Icons.image_outlined),
  );
}

class _AttachmentTile extends StatelessWidget {
  final Widget? preview;
  final VoidCallback? onRename;
  final Attachment attachment;
  final bool present;
  final bool remoteHeld;
  final bool hasSavedCopy;
  final bool downloading;
  final bool? checked;
  final VoidCallback? onTapSelect;
  final VoidCallback onOpen;
  final VoidCallback onDownload;
  final VoidCallback onFreeSpace;
  final VoidCallback onSave;
  final VoidCallback onCopy;
  final VoidCallback onLocation;
  final VoidCallback onDelete;

  const _AttachmentTile({
    this.preview,
    this.onRename,
    required this.attachment,
    required this.present,
    required this.remoteHeld,
    required this.hasSavedCopy,
    required this.downloading,
    this.checked,
    this.onTapSelect,
    required this.onOpen,
    required this.onDownload,
    required this.onFreeSpace,
    required this.onSave,
    required this.onCopy,
    required this.onLocation,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDesktop = Platform.isWindows;
    final dotColor = present
        ? Colors.green
        : (remoteHeld ? Colors.red : scheme.outline);
    final dotMessage = present
        ? 'Файл есть на этом устройстве'
        : remoteHeld
            ? 'Файл есть на другом устройстве'
            : 'Файла нет ни на одном устройстве';
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTapSelect ?? (present ? onOpen : null),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
        child: Row(children: [
          if (checked != null) ...[
            SelectDot(checked: checked!),
            const SizedBox(width: 4),
          ],
          Tooltip(
            message: dotMessage,
            child: SizedBox(
              width: 40,
              height: 40,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  if (preview != null)
                    ClipRRect(borderRadius: BorderRadius.circular(8), child: preview)
                  else
                    Icon(attachment.isImage ? Icons.image_outlined : Icons.insert_drive_file_outlined),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: dotColor,
                        shape: BoxShape.circle,
                        border: Border.all(color: scheme.surface, width: 2),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(attachment.label, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text('${attachment.sizeLabel} · ${present ? 'На устройстве' : remoteHeld ? 'Удалённо' : 'Недоступен'}',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (!present && downloading)
            const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
          else if (!present && remoteHeld)
            IconButton(
              tooltip: 'Скачать с другого устройства',
              icon: const Icon(Icons.download_outlined),
              onPressed: onDownload,
            ),
          PopupMenuButton<String>(
            tooltip: 'Действия',
            position: PopupMenuPosition.under,
            menuPadding: const EdgeInsets.all(8),
            color: Theme.of(context).cardTheme.color,
            surfaceTintColor: Colors.transparent,
            elevation: 12,
            shadowColor: Colors.black.withValues(alpha: 0.3),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: scheme.outlineVariant)),
            onSelected: (v) {
              switch (v) {
                case 'rename':
                  onRename?.call();
                case 'open':
                  onOpen();
                case 'save':
                  onSave();
                case 'copy':
                  onCopy();
                case 'location':
                  onLocation();
                case 'free':
                  onFreeSpace();
                case 'delete':
                  onDelete();
              }
            },
            itemBuilder: (_) => [
              if (onRename != null) const PopupMenuItem(value: 'rename', child: Text('Изменить название')),
              if (present) const PopupMenuItem(value: 'open', child: Text('Открыть файл')),
              if (present) const PopupMenuItem(value: 'save', child: Text('Сохранить копию')),
              if (present) const PopupMenuItem(value: 'copy', child: Text('Копировать в буфер обмена')),
              if (isDesktop && hasSavedCopy)
                const PopupMenuItem(value: 'location', child: Text('Показать в папке')),
              if (present && remoteHeld) const PopupMenuItem(value: 'free', child: Text('Освободить место')),
              const PopupMenuItem(value: 'delete', child: Text('Удалить вложение')),
            ],
          ),
        ]),
      ),
        ),
      ),
    );
  }
}

