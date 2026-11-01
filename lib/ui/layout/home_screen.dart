import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/note.dart';
import '../../sync/sync_service.dart';
import '../conflicts/conflict_screen.dart';
import '../devices/devices_screen.dart';
import '../editor/note_editor.dart';
import '../notes_list/notes_list.dart';
import '../providers.dart';
import '../settings/settings_screen.dart';
import '../theme/app_theme.dart';
import '../widgets/sync_status_chip.dart';

/// Adaptive root: list + editor side-by-side on wide screens,
/// list -> editor navigation on phones.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});
  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> with WidgetsBindingObserver {
  final _searchFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) ref.read(syncProvider).wakeUp();
  }

  void _newNote(bool wide) {
    ref.read(searchQueryProvider.notifier).set('');
    final n = ref.read(storeProvider).createNote();
    _open(n, wide);
  }

  void _open(Note n, bool wide) {
    if (wide) {
      ref.read(selectedNoteProvider.notifier).select(n.id);
    } else {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => MobileEditorPage(noteId: n.id)));
    }
  }

  void _onStatusTap(SyncStatus s) {
    if (s.state == SyncState.conflict) {
      openConflicts(context);
    } else {
      Navigator.push(context, MaterialPageRoute(builder: (_) => const DevicesScreen()));
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= kWideLayout;
    final sync = ref.watch(syncProvider);
    final status = ref.watch(syncStatusProvider).value ?? sync.currentStatus;
    final selected = ref.watch(selectedNoteProvider);

    final actions = <Widget>[
      SyncStatusChip(status: status, compact: !wide, onTap: () => _onStatusTap(status)),
      IconButton(
        tooltip: 'Устройства',
        icon: const Icon(Icons.devices_outlined),
        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DevicesScreen())),
      ),
      IconButton(
        tooltip: 'Настройки',
        icon: const Icon(Icons.settings_outlined),
        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
      ),
      const SizedBox(width: 8),
    ];

    final listPane = Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: SearchField(focusNode: _searchFocus),
      ),
      Expanded(
        child: NotesList(
          selectedId: wide ? selected : null,
          large: !wide,
          onOpen: (n) => _open(n, wide),
        ),
      ),
    ]);

    final body = wide
        ? Row(children: [
            SizedBox(width: 360, child: listPane),
            VerticalDivider(width: 1, color: Theme.of(context).dividerTheme.color),
            Expanded(
              child: selected == null || ref.watch(storeProvider).getNote(selected)?.deleted != false
                  ? _EmptyEditor(onCreate: () => _newNote(true))
                  : NoteEditor(
                      key: ValueKey(selected),
                      noteId: selected,
                      onDeleted: () => ref.read(selectedNoteProvider.notifier).select(null),
                    ),
            ),
          ])
        : listPane;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): () => _newNote(wide),
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () => _searchFocus.requestFocus(),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('NoteVibe'),
            actions: actions,
          ),
          body: body,
          floatingActionButton: wide
              ? null
              : FloatingActionButton(
                  tooltip: 'Новая заметка',
                  onPressed: () => _newNote(false),
                  child: const Icon(Icons.add),
                ),
        ),
      ),
    );
  }
}

class _EmptyEditor extends StatelessWidget {
  final VoidCallback onCreate;
  const _EmptyEditor({required this.onCreate});
  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.sticky_note_2_outlined, size: 64, color: s.outlineVariant),
        const SizedBox(height: 16),
        Text('Выберите заметку или создайте новую', style: TextStyle(color: s.outline)),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: onCreate,
          icon: const Icon(Icons.add),
          label: const Text('Новая заметка  (Ctrl+N)'),
        ),
      ]),
    );
  }
}

class MobileEditorPage extends ConsumerStatefulWidget {
  final String noteId;
  const MobileEditorPage({super.key, required this.noteId});
  @override
  ConsumerState<MobileEditorPage> createState() => _MobileEditorPageState();
}

class _MobileEditorPageState extends ConsumerState<MobileEditorPage> {
  final _editorKey = GlobalKey<NoteEditorState>();

  @override
  Widget build(BuildContext context) {
    final noteId = widget.noteId;
    final status = ref.watch(syncStatusProvider).value ?? ref.read(syncProvider).currentStatus;
    return Scaffold(
      appBar: AppBar(
        actions: [
          SyncStatusChip(
            status: status,
            compact: true,
            onTap: status.state == SyncState.conflict ? () => openConflicts(context, noteId) : null,
          ),
          IconButton(
            tooltip: 'Удалить',
            iconSize: 26,
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _editorKey.currentState?.confirmDelete(),
          ),
        ],
      ),
      body: NoteEditor(
        key: _editorKey,
        noteId: noteId,
        compact: true,
        onDeleted: () => Navigator.of(context).maybePop(),
      ),
    );
  }
}
