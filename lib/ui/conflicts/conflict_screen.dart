import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../domain/conflict.dart';
import '../../domain/note.dart';
import '../providers.dart';

Future<void> openConflicts(BuildContext context, [String? noteId]) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => ConflictScreen(noteId: noteId)));

/// Lists unresolved conflicts and lets the user pick a version.
class ConflictScreen extends ConsumerWidget {
  final String? noteId;
  const ConflictScreen({super.key, this.noteId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(storeChangesProvider);
    final store = ref.watch(storeProvider);
    final list = noteId == null ? store.allConflicts() : store.conflictsFor(noteId!);
    return Scaffold(
      appBar: AppBar(title: const Text('Конфликты')),
      body: list.isEmpty
          ? const Center(child: Text('Конфликтов нет'))
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: list.length,
              separatorBuilder: (_, _) => const SizedBox(height: 16),
              itemBuilder: (_, i) {
                final c = list[i];
                final current = store.getNote(c.noteId);
                if (current == null) return const SizedBox.shrink();
                return _ConflictCard(
                  conflict: c,
                  current: current,
                  onChoose: (choice) {
                    store.resolveConflict(c.id, choice);
                    final msg = switch (choice) {
                      ConflictChoice.keepCurrent => 'Оставлена текущая версия',
                      ConflictChoice.takeOther => 'Применена другая версия',
                      ConflictChoice.keepBoth => 'Другая версия сохранена отдельной заметкой',
                    };
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
                  },
                );
              },
            ),
    );
  }
}

class _ConflictCard extends StatelessWidget {
  final NoteConflict conflict;
  final Note current;
  final ValueChanged<ConflictChoice> onChoose;
  const _ConflictCard({required this.conflict, required this.current, required this.onChoose});

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width > 700;
    final a = _Version(label: 'Текущая версия', note: current);
    final b = _Version(label: 'Другая версия', note: conflict.other);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(current.displayTitle, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          if (wide)
            IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Expanded(child: a),
                const SizedBox(width: 12),
                Expanded(child: b),
              ]),
            )
          else ...[a, const SizedBox(height: 12), b],
          const SizedBox(height: 16),
          LayoutBuilder(builder: (context, c) {
            Widget label(String s) =>
                FittedBox(fit: BoxFit.scaleDown, child: Text(s, maxLines: 1, softWrap: false));
            final buttons = [
              OutlinedButton(
                  onPressed: () => onChoose(ConflictChoice.keepCurrent), child: label('Оставить текущую')),
              OutlinedButton(
                  onPressed: () => onChoose(ConflictChoice.takeOther), child: label('Взять другую')),
              FilledButton(
                  onPressed: () => onChoose(ConflictChoice.keepBoth), child: label('Сохранить обе')),
            ];
            if (c.maxWidth < 480 * MediaQuery.textScalerOf(context).scale(1)) {
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (final b in buttons.reversed) ...[b, const SizedBox(height: 8)],
              ]);
            }
            return Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.end, children: buttons);
          }),
        ]),
      ),
    );
  }
}

class _Version extends StatelessWidget {
  final String label;
  final Note note;
  const _Version({required this.label, required this.note});

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: s.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('$label · ${DateFormat('d MMM HH:mm', 'ru').format(note.updatedAt)}',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(color: s.primary)),
        const SizedBox(height: 6),
        Text(note.title.isEmpty ? '(без заголовка)' : note.title,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(note.plainText.trim(), maxLines: 12, overflow: TextOverflow.ellipsis),
      ]),
    );
  }
}
