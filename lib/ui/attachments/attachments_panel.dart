import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/attachment.dart';
import '../providers.dart';
import 'attachment_service.dart';

final attachmentServiceProvider = Provider<AttachmentService>((ref) {
  final s = ref.watch(servicesProvider);
  return AttachmentService(s.store, s.attachments);
});

/// Attachments of one note: add, open, save a copy, delete.
///
/// Status dot: green = file is on this device, grey = file is missing here.
/// Missing files come from another device; downloading them is the next stage.
class AttachmentsPanel extends ConsumerWidget {
  final String noteId;
  const AttachmentsPanel({super.key, required this.noteId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(storeProvider);
    final svc = ref.watch(attachmentServiceProvider);
    final scheme = Theme.of(context).colorScheme;
    // Rebuild when attachments or notes change.
    ref.watch(storeChangesProvider);
    final items = store.attachmentsFor(noteId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          Expanded(child: Text('Вложения', style: Theme.of(context).textTheme.titleSmall)),
          TextButton.icon(
            onPressed: () => _add(context, svc),
            icon: const Icon(Icons.attach_file, size: 18),
            label: const FittedBox(fit: BoxFit.scaleDown, child: Text('Добавить', maxLines: 1, softWrap: false)),
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
            onOpen: () => _run(context, () => svc.open(a)),
            onSave: () => _saveCopy(context, svc, a),
            onDelete: () => _confirmRemove(context, svc, a),
          ),
      ],
    );
  }

  Future<void> _add(BuildContext context, AttachmentService svc) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final r = await svc.pickAndAttach(noteId);
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
  final VoidCallback onOpen;
  final VoidCallback onSave;
  final VoidCallback onDelete;

  const _AttachmentTile({
    required this.attachment,
    required this.present,
    required this.onOpen,
    required this.onSave,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dotColor = present ? Colors.green : scheme.outline;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: present ? onOpen : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Icon(attachment.isImage ? Icons.image_outlined : Icons.insert_drive_file_outlined),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(attachment.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(attachment.sizeLabel, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          Tooltip(
            message: present ? 'Файл есть на этом устройстве' : 'Файла нет на этом устройстве',
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'Действия',
            onSelected: (v) {
              switch (v) {
                case 'save':
                  onSave();
                case 'delete':
                  onDelete();
              }
            },
            itemBuilder: (_) => [
              if (present) const PopupMenuItem(value: 'save', child: Text('Сохранить копию')),
              const PopupMenuItem(value: 'delete', child: Text('Удалить')),
            ],
          ),
        ]),
      ),
    );
  }
}
