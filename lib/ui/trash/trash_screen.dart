import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/note.dart';
import '../notes_list/notes_list.dart';
import '../providers.dart';

/// Deleted notes. They can be restored or removed for good; the trash also
/// empties itself after the period set in settings.
class TrashScreen extends ConsumerStatefulWidget {
  const TrashScreen({super.key});
  @override
  ConsumerState<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends ConsumerState<TrashScreen> {
  @override
  void dispose() {
    ref.read(selectionProvider.notifier).clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selecting = ref.watch(selectionProvider);
    final period = ref.watch(trashPeriodProvider);
    final count = ref.watch(trashedNotesProvider).length;
    return Scaffold(
      appBar: selecting != null
          ? AppBar(
              leading: IconButton(
                tooltip: 'Отменить выбор',
                icon: const Icon(Icons.close),
                onPressed: () => ref.read(selectionProvider.notifier).clear(),
              ),
              title: Text('Выбрано: ${selecting.length}'),
              actions: [
                IconButton(
                  tooltip: 'Восстановить',
                  icon: const Icon(Icons.restore),
                  onPressed: selecting.isEmpty
                      ? null
                      : () {
                          ref.read(storeProvider).restoreNotes(selecting);
                          ref.read(selectionProvider.notifier).clear();
                        },
                ),
                IconButton(
                  tooltip: 'Удалить навсегда',
                  icon: const Icon(Icons.delete_forever_outlined),
                  onPressed: selecting.isEmpty ? null : () => _deleteForever(selecting),
                ),
                const SizedBox(width: 8),
              ],
            )
          : AppBar(
              title: const Text('Корзина'),
              actions: [
                if (count > 0)
                  IconButton(
                    tooltip: 'Выбрать заметки',
                    icon: const Icon(Icons.checklist),
                    onPressed: () => ref.read(selectionProvider.notifier).start(),
                  ),
                if (count > 0)
                  IconButton(
                    tooltip: 'Очистить корзину',
                    icon: const Icon(Icons.delete_sweep_outlined),
                    onPressed: () => _deleteForever(ref.read(trashedNotesProvider).map((n) => n.id).toSet()),
                  ),
                const SizedBox(width: 8),
              ],
            ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text(
            period.days < 0
                ? 'Заметки хранятся, пока вы их не удалите.'
                : 'Заметки удаляются навсегда через ${period.days} ${_daysWord(period.days)} в корзине.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        Expanded(child: NotesList(trashed: true, large: true, onOpen: _open)),
      ]),
    );
  }

  void _open(Note n) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.restore),
            title: const Text('Восстановить'),
            onTap: () {
              Navigator.pop(c);
              ref.read(storeProvider).restoreNotes([n.id]);
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_forever_outlined),
            title: const Text('Удалить навсегда'),
            onTap: () {
              Navigator.pop(c);
              _deleteForever({n.id});
            },
          ),
        ]),
      ),
    );
  }

  Future<void> _deleteForever(Set<String> ids) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Удалить навсегда (${ids.length})?'),
        content: const Text('Заметки будут удалены на всех синхронизированных устройствах. Это нельзя отменить.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Удалить')),
        ],
      ),
    );
    if (ok != true) return;
    ref.read(storeProvider).deleteNotes(ids);
    ref.read(selectionProvider.notifier).clear();
  }

  static String _daysWord(int n) {
    final m10 = n % 10;
    final m100 = n % 100;
    if (m10 == 1 && m100 != 11) return 'день';
    if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return 'дня';
    return 'дней';
  }
}
