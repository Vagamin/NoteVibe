import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    final previewLines = ref.watch(previewLinesProvider);
    final picked = ref.watch(selectionProvider);
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
      itemBuilder: (context, i) {
        final n = notes[i];
        final inSelection = picked?.contains(n.id) ?? false;
        final selecting = picked != null;
        return NoteCard(
          note: n,
          selected: n.id == selectedId || inSelection,
          large: large,
          previewLines: previewLines,
          checked: selecting ? inSelection : null,
          onTap: () {
            if (selecting) {
              ref.read(selectionProvider.notifier).toggle(n.id);
            } else {
              onOpen(n);
            }
          },
          onLongPress: () => ref.read(selectionProvider.notifier).toggle(n.id),
          onCtrlTap: () => ref.read(selectionProvider.notifier).toggle(n.id),
        );
      },
    );
  }
}

class NoteCard extends StatelessWidget {
  final Note note;
  final bool selected;
  final bool large;
  final PreviewLines previewLines;

  /// Null when selection mode is off; otherwise whether the card is checked.
  final bool? checked;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onCtrlTap;

  const NoteCard({
    super.key,
    required this.note,
    required this.onTap,
    this.selected = false,
    this.large = false,
    this.previewLines = PreviewLines.two,
    this.checked,
    this.onLongPress,
    this.onCtrlTap,
  });

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final preview = note.plainText.trim().replaceAll(RegExp(r'\s+'), ' ');
    final body = note.title.trim().isEmpty && preview.isNotEmpty
        ? preview.substring(note.displayTitle.length.clamp(0, preview.length)).trim()
        : preview;
    final showBody = previewLines != PreviewLines.titleOnly && body.isNotEmpty;
    final importantColor = Colors.amber.shade700;
    final background = note.important
        ? Color.alphaBlend(importantColor.withValues(alpha: 0.14), s.surfaceContainerLow)
        : null;
    return Card(
      color: selected ? s.primaryContainer : background,
      shape: note.important
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: importantColor.withValues(alpha: 0.6)),
            )
          : null,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          if (onCtrlTap != null && HardwareKeyboard.instance.isControlPressed) {
            onCtrlTap!();
          } else {
            onTap();
          }
        },
        onLongPress: onLongPress,
        child: Padding(
          padding: EdgeInsets.all(large ? 18 : 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              if (checked != null) ...[
                Icon(checked! ? Icons.check_circle : Icons.radio_button_unchecked,
                    size: 20, color: checked! ? s.primary : s.outline),
                const SizedBox(width: 8),
              ],
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
            if (showBody) ...[
              const SizedBox(height: 6),
              Text(body,
                  maxLines: previewLines.lines == 0 ? null : previewLines.lines,
                  overflow: previewLines.lines == 0 ? TextOverflow.clip : TextOverflow.ellipsis,
                  style: t.bodyMedium?.copyWith(color: s.onSurfaceVariant)),
            ],
            if (note.important) ...[
              const SizedBox(height: 8),
              Row(children: [
                Icon(Icons.star, size: 14, color: importantColor),
                const SizedBox(width: 4),
                Text('ВАЖНОЕ',
                    style: t.labelSmall?.copyWith(color: importantColor, fontWeight: FontWeight.w600, letterSpacing: 0.6)),
              ]),
            ],
          ]),
        ),
      ),
    );
  }
}

