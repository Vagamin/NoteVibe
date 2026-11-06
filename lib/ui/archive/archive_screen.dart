import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/note.dart';
import '../editor/note_editor.dart';
import '../notes_list/notes_list.dart';
import '../providers.dart';

/// Archived notes. Notes are read here and can be returned or deleted in bulk.
class ArchiveScreen extends ConsumerStatefulWidget {
  const ArchiveScreen({super.key});
  @override
  ConsumerState<ArchiveScreen> createState() => _ArchiveScreenState();
}

class _ArchiveScreenState extends ConsumerState<ArchiveScreen> {
  bool _searchVisible = false;
  final _searchFocus = FocusNode();
  late NoteSelection _selection;
  @override
  void initState() { super.initState(); _selection = ref.read(selectionProvider.notifier); }
  void _toggleSearch() {
    setState(() => _searchVisible = !_searchVisible);
    if (_searchVisible) {
      _searchFocus.requestFocus();
    } else {
      _searchFocus.unfocus();
      ref.read(searchQueryProvider.notifier).set('');
    }
  }
  @override
  void dispose() {
    _selection.clear();
    _searchFocus.dispose();
    super.dispose();
  }

  void _open(Note n) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => ArchivedNotePage(noteId: n.id)));
  }

  @override
  Widget build(BuildContext context) {
    final selecting = ref.watch(selectionProvider);
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
                  tooltip: 'Вернуть из архива',
                  icon: const Icon(Icons.unarchive_outlined),
                  onPressed: selecting.isEmpty
                      ? null
                      : () {
                          ref.read(storeProvider).setArchived(selecting, false);
                          ref.read(selectionProvider.notifier).clear();
                        },
                ),
                IconButton(
                  tooltip: 'Удалить выбранные',
                  icon: const Icon(Icons.delete_sweep_outlined),
                  onPressed: selecting.isEmpty ? null : () => _bulkDelete(selecting),
                ),
                const SizedBox(width: 8),
              ],
            )
          : AppBar(
              title: _searchVisible ? SearchField(focusNode: _searchFocus) : const Text('Архив'),
              actions: [
                IconButton(tooltip: _searchVisible ? 'Закрыть поиск' : 'Поиск',
                  icon: Icon(_searchVisible ? Icons.close : Icons.search), onPressed: _toggleSearch),
                IconButton(
                  tooltip: 'Выбрать заметки',
                  icon: const Icon(Icons.checklist),
                  onPressed: () => ref.read(selectionProvider.notifier).start(),
                ),
                const SizedBox(width: 8),
              ],
            ),
      body: Column(children: [
        Expanded(child: NotesList(archived: true, large: true, onOpen: _open)),
      ]),
    );
  }

  Future<void> _bulkDelete(Set<String> ids) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Удалить заметки (${ids.length})?'),
        content: const Text('Заметки будут удалены на всех синхронизированных устройствах.'),
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
}

/// Reading an archived note on a phone; the editor is the same as in the list.
class ArchivedNotePage extends ConsumerWidget {
  final String noteId;
  const ArchivedNotePage({super.key, required this.noteId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final note = ref.watch(storeProvider).getNote(noteId);
    ref.watch(storeChangesProvider);
    return Scaffold(
      appBar: AppBar(
        actions: [
          IconButton(
            tooltip: 'Вернуть из архива',
            icon: const Icon(Icons.unarchive_outlined),
            onPressed: () {
              ref.read(storeProvider).setArchived([noteId], false);
              Navigator.of(context).maybePop();
            },
          ),
        ],
      ),
      body: note == null || note.deleted
          ? const Center(child: Text('Заметка удалена'))
          : NoteEditor(noteId: noteId, compact: true, onDeleted: () => Navigator.of(context).maybePop()),
    );
  }
}
