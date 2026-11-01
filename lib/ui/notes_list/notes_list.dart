import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../domain/note.dart';
import '../providers.dart';

String formatShortDate(DateTime d) {
  final now = DateTime.now();
  if (d.year == now.year && d.month == now.month && d.day == now.day) {
    return DateFormat('HH:mm').format(d);
  }
  if (d.year == now.year) return DateFormat('d MMM', 'ru').format(d);
  return DateFormat('d.MM.yy').format(d);
}

class SearchField extends ConsumerStatefulWidget {
  final FocusNode? focusNode;
  const SearchField({super.key, this.focusNode});

  @override
  ConsumerState<SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends ConsumerState<SearchField> {
  final _c = TextEditingController();

  @override
  void initState() {
    super.initState();
    _c.text = ref.read(searchQueryProvider);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _c,
      focusNode: widget.focusNode,
      onChanged: (v) {
        ref.read(searchQueryProvider.notifier).set(v);
        setState(() {});
      },
      decoration: InputDecoration(
        hintText: 'Поиск заметок',
        prefixIcon: const Icon(Icons.search),
        suffixIcon: _c.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Очистить',
                icon: const Icon(Icons.close),
                onPressed: () {
                  _c.clear();
                  ref.read(searchQueryProvider.notifier).set('');
                  setState(() {});
                },
              ),
      ),
    );
  }
}

class NotesList extends ConsumerWidget {
  final String? selectedId;
  final ValueChanged<Note> onOpen;
  final bool large;
  const NotesList({super.key, required this.onOpen, this.selectedId, this.large = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notes = ref.watch(notesProvider);
    final query = ref.watch(searchQueryProvider);
    if (notes.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(query.isEmpty ? Icons.edit_note : Icons.search_off,
                size: 56, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(
              query.isEmpty ? 'Заметок пока нет.\nНажмите «+», чтобы создать первую.' : 'Ничего не найдено',
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.outline),
            ),
          ]),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
      itemCount: notes.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, i) => NoteCard(
        note: notes[i],
        selected: notes[i].id == selectedId,
        large: large,
        onTap: () => onOpen(notes[i]),
      ),
    );
  }
}

class NoteCard extends StatelessWidget {
  final Note note;
  final bool selected;
  final bool large;
  final VoidCallback onTap;
  const NoteCard({super.key, required this.note, required this.onTap, this.selected = false, this.large = false});

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final preview = note.plainText.trim().replaceAll(RegExp(r'\s+'), ' ');
    final body = note.title.trim().isEmpty && preview.isNotEmpty
        ? preview.substring(note.displayTitle.length.clamp(0, preview.length)).trim()
        : preview;
    return Card(
      color: selected ? s.primaryContainer : null,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.all(large ? 18 : 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text(note.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: (large ? t.titleMedium : t.titleSmall)?.copyWith(fontWeight: FontWeight.w600)),
              ),
              if (note.hasConflict)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Tooltip(
                    message: 'Конфликт версий',
                    child: Icon(Icons.call_split, size: 18, color: s.error),
                  ),
                ),
              const SizedBox(width: 8),
              Text(formatShortDate(note.updatedAt), style: t.bodySmall?.copyWith(color: s.outline)),
            ]),
            if (body.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(body,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: t.bodyMedium?.copyWith(color: s.onSurfaceVariant)),
            ],
          ]),
        ),
      ),
    );
  }
}
