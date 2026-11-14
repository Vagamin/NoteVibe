import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/note.dart';
import '../../data/note_store.dart';
import '../providers.dart';
import 'notes_list.dart';

class FolderPicker extends ConsumerWidget {
  const FolderPicker({super.key});

  Future<void> _name(BuildContext context, WidgetRef ref, [Note? folder, Set<String>? moveIds]) async {
    if (folder == null && ref.read(storeProvider).listFolders().length >= NoteStore.maxFolders) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Можно создать не больше 20 папок')));
      return;
    }
    final controller = TextEditingController(text: folder?.title ?? '');
    final name = await showDialog<String>(context: context, builder: (c) => AlertDialog(
      title: Text(folder == null ? 'Новая папка' : 'Переименовать папку'),
      content: SizedBox(width: 320, child: TextField(controller: controller, autofocus: true, maxLength: 80,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(labelText: 'Название папки', border: OutlineInputBorder()),
        onSubmitted: (v) { if (v.trim().isNotEmpty && v.trim().length <= 80) Navigator.pop(c, v.trim()); })),
      actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Отмена')),
        FilledButton(onPressed: () { if (controller.text.trim().isNotEmpty) Navigator.pop(c, controller.text.trim()); }, child: const Text('Сохранить'))],
    ));
    if (name != null) {
      final store = ref.read(storeProvider);
      if (folder == null) {
        try {
          final created = store.createFolder(name);
          if (moveIds != null) {
            store.moveToFolder(moveIds, created.id);
            ref.read(selectionProvider.notifier).clear();
          }
          ref.read(folderSelectionProvider.notifier).select(created.id);
        } on StateError catch (error) {
          if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
        }
      } else {
        store.updateNote(folder.id, title: name);
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    controller.dispose();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(storeChangesProvider);
    final store = ref.watch(storeProvider);
    if (!ref.watch(foldersEnabledProvider)) return const SizedBox.shrink();
    final folders = store.listFolders();
    final selected = ref.watch(folderSelectionProvider);
    final picked = ref.watch(selectionProvider);
    final moving = picked != null && picked.isNotEmpty;
    final current = folders.where((f) => f.id == selected).firstOrNull;
    final title = selected == null ? 'Все заметки' : current?.title ?? 'Без папки';
    final notes = store.listNotes();
    final ids = folders.map((f) => f.id).toSet();
    final scheme = Theme.of(context).colorScheme;
    if (!moving) {
      final heading = Tooltip(message: 'Удерживайте, чтобы открыть папки', child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _menu(context, ref),
        onLongPress: () => _menu(context, ref),
        onSecondaryTap: () => _menu(context, ref),
        child: Padding(padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(selected == null ? 'NoteVibe' : title,
            maxLines: 1, overflow: TextOverflow.ellipsis)),
      ));
      if (MediaQuery.sizeOf(context).width < 800) return heading;
      final boards = boardIds(store);
      void step(int delta) {
        final index = boards.indexOf(selected);
        ref.read(folderSelectionProvider.notifier).select(boards[((index < 0 ? 0 : index) + delta) % boards.length]);
      }
      return Row(mainAxisSize: MainAxisSize.min, children: [
        Flexible(child: heading),
        const SizedBox(width: 8),
        _FolderArrow(tooltip: 'Предыдущая папка (Alt+←)', icon: Icons.chevron_left,
          onTap: boards.length > 1 ? () => step(-1) : null),
        const SizedBox(width: 6),
        _FolderArrow(tooltip: 'Следующая папка (Alt+→)', icon: Icons.chevron_right,
          onTap: boards.length > 1 ? () => step(1) : null),
      ]);
    }
    return Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 0), child: Material(
      shadowColor: Colors.black.withValues(alpha: 0.3),
      color: Theme.of(context).cardTheme.color ?? scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5))),
      clipBehavior: Clip.antiAlias,
      child: Row(children: [
      Expanded(child: InkWell(
        onTap: () async {
          final choice = await showDialog<String>(context: context, builder: (c) => SimpleDialog(
            title: Row(children: [Icon(moving ? Icons.drive_file_move_outlined : Icons.folder_outlined),
              const SizedBox(width: 12), Expanded(child: Text(moving ? 'Переместить в папку' : 'Папки'))]),
            contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
            children: [
              if (!moving) _FolderOption(icon: Icons.notes_outlined, title: 'Все заметки', count: notes.length,
                selected: selected == null, onTap: () => Navigator.pop(c, '@all')),
              _FolderOption(icon: Icons.folder_off_outlined, title: 'Без папки',
                count: notes.where((n) => !ids.contains(n.folderId)).length,
                selected: !moving && selected != null && current == null, onTap: () => Navigator.pop(c, '')),
              if (folders.isNotEmpty) const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Divider(height: 20)),
              for (final folder in folders) _FolderOption(icon: Icons.folder_outlined, title: folder.title,
                count: notes.where((n) => n.folderId == folder.id).length,
                selected: !moving && selected == folder.id, onTap: () => Navigator.pop(c, folder.id)),
              if (moving) ...[
                const Divider(height: 16),
                _FolderOption(icon: Icons.create_new_folder_outlined,
                  title: folders.length >= NoteStore.maxFolders ? 'Лимит: 20 папок' : 'Переместить в новую папку',
                  onTap: folders.length >= NoteStore.maxFolders ? null : () => Navigator.pop(c, '@new')),
              ],
              if (!moving) ...[
                const SizedBox(height: 8),
                _FolderOption(icon: Icons.create_new_folder_outlined,
                  title: folders.length >= NoteStore.maxFolders ? 'Лимит: 20 папок' : 'Создать папку',
                  onTap: folders.length >= NoteStore.maxFolders ? null : () => Navigator.pop(c, '@new')),
              ],
            ],
          ));
          if (choice == null || !context.mounted) return;
          if (choice == '@new') { await _name(context, ref, null, moving ? Set<String>.of(picked) : null); return; }
          if (moving) {
            store.moveToFolder(picked, choice.isEmpty ? null : choice);
            ref.read(selectionProvider.notifier).clear();
          } else {
            ref.read(folderSelectionProvider.notifier).select(choice == '@all' ? null : choice);
          }
        },
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          child: Row(children: [
            Icon(moving ? Icons.drive_file_move_outlined : Icons.folder_outlined, size: 20, color: scheme.primary),
            const SizedBox(width: 10),
            Expanded(child: Text(moving ? 'Переместить (${picked.length})' : title,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(color: scheme.primary))),
            const SizedBox(width: 8), Icon(Icons.expand_more, size: 20, color: scheme.primary),
          ])),
      )),
       if (current != null && !moving) Tooltip(message: 'Управление папкой', child: InkWell(
        child: const SizedBox(width: 48, height: 48, child: Icon(Icons.more_horiz)),
        onTap: () => _manage(context, ref, current))),
    ])));
  }

  Future<void> _menu(BuildContext context, WidgetRef ref) async {
    final action = await showDialog<String>(context: context, builder: (c) => Consumer(
      builder: (context, ref, _) {
        ref.watch(storeChangesProvider);
        final store = ref.watch(storeProvider);
        final folders = store.listFolders();
        final selected = ref.watch(folderSelectionProvider);
        final notes = store.listNotes();
        final folderIds = folders.map((f) => f.id).toSet();
        return SimpleDialog(insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          title: SizedBox(width: 380, child: Row(children: [
          const Icon(Icons.folder_outlined), const SizedBox(width: 12),
          const Expanded(child: Text('Папки')),
          Text('${folders.length}/${NoteStore.maxFolders}', style: Theme.of(context).textTheme.labelMedium),
          IconButton(tooltip: 'Закрыть', onPressed: () => Navigator.pop(c), icon: const Icon(Icons.close)),
        ])),
          contentPadding: const EdgeInsets.fromLTRB(12, 4, 12, 12), children: [
            SizedBox(width: 380, child: _FolderOption(icon: Icons.notes_outlined, title: 'NoteVibe',
              count: notes.length, selected: selected == null,
              onTap: () => Navigator.pop(c, '@all'))),
            for (final id in boardIds(store).whereType<String>()) _FolderOption(
                icon: id.isEmpty ? Icons.folder_off_outlined : Icons.folder_outlined,
                 title: id.isEmpty ? 'Без папки' : folders.firstWhere((f) => f.id == id).title,
                count: notes.where((n) => id.isEmpty ? !folderIds.contains(n.folderId) : n.folderId == id).length,
                selected: selected == id, onTap: () => Navigator.pop(c, id),
                onManage: id.isEmpty ? null : () async {
                  final folder = store.getNote(id);
                  if (folder != null) await _manage(context, ref, folder);
                }),
            const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Divider(height: 16)),
            _FolderOption(icon: Icons.create_new_folder_outlined,
              title: folders.length >= NoteStore.maxFolders ? 'Лимит: 20 папок' : 'Создать папку',
              onTap: folders.length >= NoteStore.maxFolders ? null : () => _name(context, ref)),
          ]);
      }));
    if (action == null || !context.mounted) return;
    if (action == '@new') {
      await _name(context, ref);
    } else if (action.startsWith('@manage:')) {
      final folder = ref.read(storeProvider).getNote(action.substring(8));
      if (folder != null) await _manage(context, ref, folder);
    } else {
      ref.read(folderSelectionProvider.notifier).select(action == '@all' ? null : action);
    }
  }

  Future<void> _manage(BuildContext context, WidgetRef ref, Note current) async {
          final store = ref.read(storeProvider);
          final action = await showDialog<String>(context: context, builder: (c) => SimpleDialog(
            insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            title: SizedBox(width: 380, child: Row(children: [
              Expanded(child: Text(current.title, maxLines: 2, overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 8),
              Tooltip(message: 'Назад к папкам',
                child: TextButton.icon(onPressed: () => Navigator.pop(c),
                  icon: const Icon(Icons.arrow_back, size: 18), label: const Text('К папкам'))),
            ])),
            contentPadding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            children: [
              _FolderOption(icon: Icons.edit_outlined, title: 'Переименовать папку', onTap: () => Navigator.pop(c, 'rename')),
              _FolderOption(icon: Icons.delete_outline, title: 'Удалить папку', onTap: () => Navigator.pop(c, 'delete')),
            ],
          ));
          if (!context.mounted) return;
          if (action == 'rename') await _name(context, ref, current);
          if (action == 'delete' && context.mounted) {
            final accepted = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
              title: const Text('Удалить папку?'),
              content: const Text('Заметки не удалятся и будут доступны в разделе «Без папки».'),
              actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Отмена')),
                FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Удалить папку'))],
            ));
            if (accepted == true) {
              store.deleteFolder(current.id);
              if (ref.read(folderSelectionProvider) == current.id) {
                ref.read(folderSelectionProvider.notifier).select('');
              }
            }
          }
  }
}

/// The same order is used by the tab strip, page swipes and keyboard navigation.
List<String?> boardIds(NoteStore store) {
  final folders = store.listFolders()..sort((a, b) {
    final order = a.createdAt.compareTo(b.createdAt);
    return order == 0 ? a.id.compareTo(b.id) : order;
  });
  final ids = folders.map((f) => f.id).toSet();
  return [null, if (store.listNotes().any((n) => !ids.contains(n.folderId))) '', ...folders.map((f) => f.id)];
}

class BoardTabs extends ConsumerStatefulWidget {
  final VoidCallback onCreate;
  final ValueChanged<Note> onManage;
  const BoardTabs({super.key, required this.onCreate, required this.onManage});

  @override
  ConsumerState<BoardTabs> createState() => _BoardTabsState();
}

class _BoardTabsState extends ConsumerState<BoardTabs> {
  final _scroll = ScrollController();
  final _keys = <String?, GlobalKey>{};

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(storeChangesProvider);
    final store = ref.watch(storeProvider);
    final folders = store.listFolders();
    final ids = boardIds(store);
    final selected = ref.watch(folderSelectionProvider);
    final effective = ids.contains(selected) ? selected : null;
    final current = folders.where((f) => f.id == effective).firstOrNull;
    final scheme = Theme.of(context).colorScheme;
    final desktop = MediaQuery.sizeOf(context).width >= 800;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = _keys[effective]?.currentContext;
      if (target != null) Scrollable.ensureVisible(target, duration: const Duration(milliseconds: 180), alignment: 0.5);
    });
    void step(int delta) {
      final index = (ids.indexOf(effective) + delta).clamp(0, ids.length - 1);
      ref.read(folderSelectionProvider.notifier).select(ids[index]);
    }
    return Material(color: Colors.transparent, child: Row(children: [
      if (desktop) IconButton(tooltip: 'Предыдущая доска (Alt+←)', icon: const Icon(Icons.chevron_left),
        onPressed: ids.indexOf(effective) > 0 ? () => step(-1) : null),
      Expanded(child: SingleChildScrollView(controller: _scroll, scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8), child: Row(children: [
          for (final id in ids) Builder(builder: (context) {
            final folder = folders.where((f) => f.id == id).firstOrNull;
            final active = effective == id;
            final title = id == null ? 'Все' : id.isEmpty ? 'Без папки' : folder!.title;
            return Semantics(selected: active, button: true, child: Tooltip(message: title,
              child: InkWell(key: _keys.putIfAbsent(id, () => GlobalKey()),
                borderRadius: BorderRadius.circular(10),
                onTap: () => ref.read(folderSelectionProvider.notifier).select(id),
                onLongPress: folder == null ? null : () => widget.onManage(folder),
                onSecondaryTap: folder == null ? null : () => widget.onManage(folder),
                child: Container(constraints: const BoxConstraints(maxWidth: 180),
                  padding: const EdgeInsets.fromLTRB(12, 14, 12, 11),
                  decoration: BoxDecoration(border: Border(bottom: BorderSide(
                    color: active ? scheme.primary : Colors.transparent, width: 3))),
                  child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: active ? scheme.primary : scheme.onSurfaceVariant,
                      fontWeight: active ? FontWeight.bold : FontWeight.w500))),
              )));
          }),
          IconButton(tooltip: folders.length >= NoteStore.maxFolders ? 'Лимит: 20 папок' : 'Создать папку',
            icon: const Icon(Icons.add), onPressed: folders.length >= NoteStore.maxFolders ? null : widget.onCreate),
        ]))),
      if (desktop) IconButton(tooltip: 'Следующая доска (Alt+→)', icon: const Icon(Icons.chevron_right),
        onPressed: ids.indexOf(effective) < ids.length - 1 ? () => step(1) : null),
      if (current != null) IconButton(tooltip: 'Управление папкой', icon: const Icon(Icons.more_horiz),
        onPressed: () => widget.onManage(current)),
    ]));
  }
}

class BoardNotesPager extends ConsumerWidget {
  final ValueChanged<Note> onOpen;
  const BoardNotesPager({super.key, required this.onOpen});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(storeChangesProvider);
    final ids = boardIds(ref.watch(storeProvider));
    return _BoardPages(key: ValueKey(ids.map((id) => id ?? '@all').join('|')), ids: ids, onOpen: onOpen);
  }
}

class _BoardPages extends ConsumerStatefulWidget {
  final List<String?> ids;
  final ValueChanged<Note> onOpen;
  const _BoardPages({super.key, required this.ids, required this.onOpen});
  @override
  ConsumerState<_BoardPages> createState() => _BoardPagesState();
}

class _BoardPagesState extends ConsumerState<_BoardPages> {
  late final PageController _controller;
  bool _publishingPage = false;

  @override
  void initState() {
    super.initState();
    final index = widget.ids.indexOf(ref.read(folderSelectionProvider));
    _controller = PageController(initialPage: widget.ids.length * 1000 + (index < 0 ? 0 : index));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ids = widget.ids;
    ref.listen(folderSelectionProvider, (previous, next) {
      if (_publishingPage || !_controller.hasClients) return;
      final index = ids.indexOf(next);
      final page = _controller.page!.round();
      final target = index < 0 ? 0 : index;
      if (page % ids.length != target) {
        _controller.jumpToPage(page - page % ids.length + target);
      }
    });
    return Listener(onPointerDown: (_) {
      // A new touch starts a new gesture, not a continuation of the previous
      // page's ballistic animation. Finish at the nearest board immediately.
      if (_controller.hasClients && _controller.position.isScrollingNotifier.value) {
        _controller.jumpToPage(_controller.page!.round());
      }
    }, child: NotificationListener<ScrollNotification>(onNotification: (notification) {
      if (notification.metrics.axis == Axis.horizontal && _controller.hasClients) {
        // Scrollable normally blocks its children while settling. That makes
        // the next vertical gesture hit only the horizontal pager instead of
        // the notes list. Keep the inner lists available for hit testing.
        _controller.position.context.setIgnorePointer(false);
      }
      return false;
    }, child: PageView.builder(controller: _controller,
      allowImplicitScrolling: true,
      physics: ids.length == 1 ? const NeverScrollableScrollPhysics() : const _SnappyPagePhysics(),
      onPageChanged: (i) {
        final id = ids[i % ids.length];
        _publishingPage = true;
        try {
          if (ref.read(folderSelectionProvider) != id) ref.read(folderSelectionProvider.notifier).select(id);
        } finally {
          _publishingPage = false;
        }
      },
      itemBuilder: (context, i) => RepaintBoundary(child: NotesList(key: PageStorageKey('board-${ids[i % ids.length]}'),
        large: true, filterBoard: true, boardId: ids[i % ids.length], onOpen: widget.onOpen)))));
  }
}

class _SnappyPagePhysics extends PageScrollPhysics {
  const _SnappyPagePhysics({super.parent});

  @override
  _SnappyPagePhysics applyTo(ScrollPhysics? ancestor) => _SnappyPagePhysics(parent: buildParent(ancestor));

  // A critically damped, faster snap: no bounce or long settling tail.
  @override
  SpringDescription get spring => SpringDescription.withDampingRatio(mass: 1, stiffness: 650, ratio: 1);
}

class _FolderArrow extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback? onTap;
  const _FolderArrow({required this.tooltip, required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) => Tooltip(message: tooltip,
    child: Semantics(button: true, enabled: onTap != null, label: tooltip,
      child: InkWell(onTap: onTap, borderRadius: BorderRadius.circular(8),
        child: SizedBox(width: 32, height: 32, child: Center(
          child: CustomPaint(size: const Size(20, 20), painter: _ChevronPainter(
            left: icon == Icons.chevron_left, color: onTap == null
            ? Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.38)
            : Theme.of(context).colorScheme.onSurface)))))));
}

class _ChevronPainter extends CustomPainter {
  final bool left;
  final Color color;
  const _ChevronPainter({required this.left, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    // Align the chevron optically with the title's visible glyphs, not the
    // centre of its line box (which includes font ascent/descent spacing).
    canvas.save();
    canvas.translate(0, 2);
    final paint = Paint()..color = color..style = PaintingStyle.stroke
      ..strokeWidth = 2..strokeCap = StrokeCap.round..strokeJoin = StrokeJoin.round;
    final outer = size.width * (left ? 0.6 : 0.4);
    final tip = size.width * (left ? 0.35 : 0.65);
    canvas.drawPath(Path()..moveTo(outer, size.height * 0.25)
      ..lineTo(tip, size.height * 0.5)..lineTo(outer, size.height * 0.75), paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ChevronPainter oldDelegate) => left != oldDelegate.left || color != oldDelegate.color;
}

class _FolderOption extends StatelessWidget {
  final IconData icon;
  final String title;
  final int? count;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onManage;
  const _FolderOption({required this.icon, required this.title, required this.onTap, this.count, this.selected = false, this.onManage});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(selected: selected, enabled: onTap != null,
      child: Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Material(
      color: selected ? scheme.secondaryContainer : scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12), clipBehavior: Clip.antiAlias,
      child: InkWell(onTap: onTap, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 40), child: Row(children: [
          Icon(icon, size: 22, color: selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(child: Text(title, style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: selected ? scheme.onSecondaryContainer : scheme.onSurface, fontWeight: FontWeight.w600))),
          if (count != null) Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: scheme.surface.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(8)),
            child: Text('$count', style: Theme.of(context).textTheme.labelMedium)),
          if (onManage != null) ...[
            const SizedBox(width: 4),
            IconButton(tooltip: 'Управление папкой', onPressed: onManage, icon: const Icon(Icons.more_horiz),
              visualDensity: VisualDensity.compact),
          ],
        ]))),
      ),
    )));
  }
}
