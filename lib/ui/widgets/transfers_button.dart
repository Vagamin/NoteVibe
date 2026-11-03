import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';

class TransfersButton extends ConsumerWidget {
  const TransfersButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(syncProvider);
    return StreamBuilder<void>(
      stream: sync.transferEvents,
      builder: (context, _) {
        final active = sync.transfers.values.where((t) => t.active).length;
        return IconButton(
          tooltip: 'Загрузки файлов',
          icon: Badge(
            isLabelVisible: active > 0,
            label: Text('$active'),
            child: const Icon(Icons.downloading_outlined),
          ),
          onPressed: () => showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              title: Row(children: [
                const Expanded(child: Text('Загрузки файлов')),
                StreamBuilder<void>(
                  stream: sync.transferEvents,
                  builder: (context, _) => IconButton(
                    tooltip: 'Очистить завершённые',
                    icon: const Icon(Icons.playlist_remove_rounded, size: 22),
                    onPressed: sync.transfers.values.any((t) => !t.active) ? sync.clearFinishedTransfers : null,
                  ),
                ),
              ]),
              content: SizedBox(
                width: 420,
                child: StreamBuilder<void>(
                  stream: sync.transferEvents,
                  builder: (context, _) {
                    final items = sync.transfers.values.toList().reversed.toList();
                    if (items.isEmpty) return const Text('Здесь появится прогресс загрузки вложений с других устройств.');
                    return ListView.separated(
                      shrinkWrap: true,
                      itemCount: items.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 20),
                      itemBuilder: (context, i) {
                        final t = items[i];
                        final progress = t.attachment.size == 0 ? 0.0 : (t.received / t.attachment.size).clamp(0.0, 1.0);
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(t.attachment.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                            const SizedBox(height: 8),
                            LinearProgressIndicator(
                              value: t.status == 'Проверка файла' ? null : progress,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            const SizedBox(height: 6),
                            Text('${t.status} · ${(t.received / 1048576).toStringAsFixed(1)} / ${(t.attachment.size / 1048576).toStringAsFixed(1)} МБ',
                              style: Theme.of(context).textTheme.bodySmall),
                          ],
                        );
                      },
                    );
                  },
                ),
              ),
              actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Закрыть'))],
            ),
          ),
        );
      },
    );
  }
}
