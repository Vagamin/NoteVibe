import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/attachment.dart';
import '../providers.dart';
import 'attachment_service.dart';

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

/// Attachments of one note: add, open, download, save a copy, delete.
///
/// Status dot: green = file is on this device, grey = file is missing here.
/// Grey files can be downloaded from another paired device.
class AttachmentsPanel extends ConsumerStatefulWidget {
  final String noteId;
  const AttachmentsPanel({super.key, required this.noteId});

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
    final scheme = Theme.of(context).colorScheme;
    // Rebuild when attachments or notes change.
    ref.watch(storeChangesProvider);
    final busy = ref.watch(downloadingProvider);
    final items = store.attachmentsFor(noteId);
    final selecting = _selected != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          Expanded(child: Text('Вложения', style: Theme.of(context).textTheme.titleSmall)),
          if (items.isNotEmpty && !selecting)
            TextButton(
              onPressed: () => setState(() => _selected = {}),
              child: const Text('Выбрать'),
            ),
          if (selecting)
            TextButton(
              onPressed: () => setState(() => _selected = null),
              child: const Text('Готово'),
            ),
          if (!selecting)
            TextButton.icon(
              onPressed: () => _add(context, svc),
              icon: const Icon(Icons.attach_file, size: 18),
              label: const FittedBox(fit: BoxFit.scaleDown, child: Text('Добавить', maxLines: 1, softWrap: false)),
            ),
        ]),
        if (selecting)
          Row(children: [
            Expanded(child: Text('Выбрано: ${_selected!.length}')),
            TextButton.icon(
              onPressed: _selected!.isEmpty ? null : () => _bulkDelete(svc, items),
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Удалить выбранные'),
            ),
          ]),
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text('Фото и файлы до 50 МБ', style: TextStyle(color: scheme.outline)),
          ),
        for (final a in items)
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
            onLocation: () => _run(context, () => svc.openLocation(a)),
            onDelete: () => _confirmRemove(context, svc, a),
            onTapSelect: selecting ? () => _toggle(a.id) : null,
          ),
      ],
    );
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
    final messenger = ScaffoldMessenger.of(context);
    try {
      final r = await svc.pickAndAttach(widget.noteId);
      if (r.failed.isNotEmpty) {
        messenger.showSnackBar(SnackBar(content: Text(r.failed.join('\n'))));
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Не удалось добавить файл: $e')));
    }
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

class _AttachmentTile extends StatelessWidget {
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
  final VoidCallback onLocation;
  final VoidCallback onDelete;

  const _AttachmentTile({
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
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTapSelect ?? (present ? onOpen : null),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          if (checked != null) ...[
            Checkbox(value: checked, onChanged: (_) => onTapSelect?.call()),
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
                Text(attachment.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(attachment.sizeLabel, style: Theme.of(context).textTheme.bodySmall),
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
            onSelected: (v) {
              switch (v) {
                case 'open':
                  onOpen();
                case 'save':
                  onSave();
                case 'location':
                  onLocation();
                case 'free':
                  onFreeSpace();
                case 'delete':
                  onDelete();
              }
            },
            itemBuilder: (_) => [
              if (present) const PopupMenuItem(value: 'open', child: Text('Открыть файл')),
              if (present) const PopupMenuItem(value: 'save', child: Text('Сохранить копию')),
              if (isDesktop && hasSavedCopy)
                const PopupMenuItem(value: 'location', child: Text('Показать в папке')),
              if (present && remoteHeld) const PopupMenuItem(value: 'free', child: Text('Освободить место')),
              const PopupMenuItem(value: 'delete', child: Text('Удалить вложение')),
            ],
          ),
        ]),
      ),
    );
  }
}

