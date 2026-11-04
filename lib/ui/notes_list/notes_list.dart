import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../domain/attachment.dart';
import '../../domain/note.dart';
import '../attachments/attachment_service.dart';
import '../attachments/attachments_panel.dart';
import '../providers.dart';
import '../select_dot.dart';
import '../voice/voice_player.dart';

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
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        fillColor: Theme.of(context).colorScheme.surfaceContainerLow,
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

  /// Shows archived notes instead of the main list.
  final bool archived;

  /// Shows notes in the trash instead of the main list.
  final bool trashed;
  const NotesList({
    super.key,
    required this.onOpen,
    this.selectedId,
    this.large = false,
    this.archived = false,
    this.trashed = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notes = ref.watch(trashed
        ? trashedNotesProvider
        : archived
            ? archivedNotesProvider
            : notesProvider);
    final query = ref.watch(searchQueryProvider);
    final previewLines = ref.watch(previewLinesProvider);
    final voicePreview = ref.watch(voicePreviewProvider);
    final fontScale = ref.watch(noteFontSizeProvider).scale;
    final picked = ref.watch(selectionProvider);
    final manual = ref.watch(manualOrderProvider) && !archived && !trashed && query.isEmpty && (picked == null || Platform.isAndroid);
    if (notes.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(query.isEmpty ? (trashed ? Icons.delete_outline : archived ? Icons.archive_outlined : Icons.edit_note) : Icons.search_off,
                size: 56, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(
              query.isNotEmpty
                  ? 'Ничего не найдено'
                  : trashed
                      ? 'Корзина пуста.'
                      : archived
                          ? 'Архив пуст.\nЗаметки сюда попадают через «В архив» в режиме выбора.'
                          : 'Заметок пока нет.\nНажмите «+», чтобы создать первую.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.outline),
            ),
          ]),
        ),
      );
    }
    Widget itemBuilder(BuildContext context, int i) {
      final n = notes[i];
      final inSelection = picked?.contains(n.id) ?? false;
      final selecting = picked != null;
      return NoteCard(
        note: n,
        voice: n.isVoice ? ref.read(storeProvider).attachmentsFor(n.id).where((a) => a.mime.startsWith('audio/')).toList() : null,
        voiceService: ref.read(attachmentServiceProvider),
        selected: n.id == selectedId || inSelection,
        large: large,
        previewLines: previewLines,
        voicePreview: voicePreview,
        fontScale: fontScale,
        checked: selecting ? inSelection : null,
        onTap: () {
          if (selecting) {
            ref.read(selectionProvider.notifier).toggle(n.id);
          } else {
            onOpen(n);
          }
        },
        onLongPress: Platform.isAndroid && selecting && manual
            ? null
            : () => ref.read(selectionProvider.notifier).toggle(n.id),
        onCtrlTap: () => ref.read(selectionProvider.notifier).toggle(n.id),
      );
    }

    if (manual) {
      final isDesktop = Platform.isWindows;
      return ReorderableListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
        itemCount: notes.length,
        buildDefaultDragHandles: false,
        proxyDecorator: (child, index, animation) => AnimatedBuilder(
          animation: animation,
          builder: (context, child) {
            final t = Curves.easeOut.transform(animation.value);
            return Transform.scale(
              scale: 1 + 0.02 * t,
              child: Material(
                type: MaterialType.transparency,
                elevation: 0,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.28 * t),
                        blurRadius: 18 * t,
                        offset: Offset(0, 6 * t),
                      ),
                    ],
                  ),
                  child: child,
                ),
              ),
            );
          },
          child: child,
        ),
        onReorderItem: (from, to) {
          final ids = notes.map((n) => n.id).toList();
          ids.insert(to, ids.removeAt(from));
          ref.read(storeProvider).setOrder(ids);
        },
        itemBuilder: (context, i) => Padding(
          key: ValueKey(notes[i].id),
          padding: const EdgeInsets.only(bottom: 10),
          child: isDesktop
              ? ReorderableDragStartListener(index: i, child: itemBuilder(context, i))
              : picked == null
                  ? itemBuilder(context, i)
                  : ReorderableDelayedDragStartListener(index: i, child: itemBuilder(context, i)),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
      itemCount: notes.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: itemBuilder,
    );
  }
}

class NoteCard extends StatelessWidget {
  final Note note;
  /// Recordings of a voice note, played by the card's mini player. Null for text notes.
  final List<Attachment>? voice;
  final AttachmentService? voiceService;
  final bool selected;
  final bool large;
  final PreviewLines previewLines;
  final VoicePreview voicePreview;
  final double fontScale;

  /// Null when selection mode is off; otherwise whether the card is checked.
  final bool? checked;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onCtrlTap;

  const NoteCard({
    super.key,
    required this.note,
    this.voice,
    this.voiceService,
    required this.onTap,
    this.selected = false,
    this.large = false,
    this.previewLines = PreviewLines.two,
    this.voicePreview = VoicePreview.all,
    this.fontScale = 1.0,    this.checked,
    this.onLongPress,
    this.onCtrlTap,
  });

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final lines = noteLines(note.content, note.plainText)
        .where((l) => l.text.isNotEmpty)
        .toList();
    if (note.title.trim().isEmpty && lines.isNotEmpty) lines.removeAt(0);
    final limit = previewLines.lines < 0 ? lines.length : previewLines.lines;
    final shown = previewLines == PreviewLines.titleOnly ? <NoteLine>[] : lines.take(limit).toList();
    final checkItems = lines.where((l) => l.kind == 'checked' || l.kind == 'unchecked').toList();
    final doneCount = checkItems.where((l) => l.kind == 'checked').length;
    final bodyStyle = t.bodyMedium?.copyWith(color: s.onSurfaceVariant, fontSize: 14 * fontScale);
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
                SelectDot(checked: checked!),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(note.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                     style: (large ? t.titleMedium : t.titleSmall)?.copyWith(
                       fontWeight: FontWeight.w600,
                       fontSize: (large ? t.titleMedium?.fontSize : t.titleSmall?.fontSize)! * fontScale,
                     )),
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
            if (shown.isNotEmpty) ...[
              const SizedBox(height: 6),
              for (final l in shown)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (l.kind == 'checked' || l.kind == 'unchecked') ...[
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Icon(
                          l.kind == 'checked' ? Icons.check_box : Icons.check_box_outline_blank,
                          size: 16 * fontScale,
                          color: l.kind == 'checked' ? s.primary : s.outline,
                        ),
                      ),
                      const SizedBox(width: 6),
                    ] else if (l.kind == 'bullet') ...[
                      Padding(
                        padding: EdgeInsets.only(top: 7 * fontScale, left: 4, right: 8),
                        child: Container(
                          width: 5 * fontScale,
                          height: 5 * fontScale,
                          decoration: BoxDecoration(color: s.outline, shape: BoxShape.circle),
                        ),
                      ),
                    ],
                    Expanded(
                      child: Text(l.text,
                          maxLines: previewLines.lines < 0 ? null : 1,
                          overflow: previewLines.lines < 0 ? TextOverflow.clip : TextOverflow.ellipsis,
                          style: l.kind == 'checked'
                              ? bodyStyle?.copyWith(decoration: TextDecoration.lineThrough, color: s.outline)
                              : bodyStyle),
                    ),
                  ]),
                ),
            ],
            if (note.isVoice && voice != null && voice!.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final a in voice!.take(voicePreview.count))
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: VoicePlayer(
                    attachment: a,
                    svc: voiceService!,
                    remoteHeld: false,
                    compact: true,
                  ),
                ),
              if (voice!.length > voicePreview.count)
                Text(voicePreview.count == 0 ? 'Записей: ${voice!.length}' : 'Ещё записей: ${voice!.length - voicePreview.count}',
                  style: t.bodySmall?.copyWith(color: s.onSurfaceVariant)),
            ] else if (note.isVoice) ...[
              const SizedBox(height: 4),
              Row(children: [
                Icon(Icons.mic, size: 14, color: s.outline),
                const SizedBox(width: 4),
                Text('Голосовая заметка', style: t.labelSmall?.copyWith(color: s.outline)),
              ]),
            ],
            if (checkItems.isNotEmpty && previewLines != PreviewLines.titleOnly) ...[
              const SizedBox(height: 4),
              Row(children: [
                Icon(Icons.checklist, size: 14, color: s.outline),
                const SizedBox(width: 4),
                Text('$doneCount из ${checkItems.length}',
                    style: t.labelSmall?.copyWith(color: s.outline)),
              ]),
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

