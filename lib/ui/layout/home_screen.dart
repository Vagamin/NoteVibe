import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/note.dart';
import '../../sync/sync_service.dart';
import '../archive/archive_screen.dart';
import '../conflicts/conflict_screen.dart';
import '../devices/devices_screen.dart';
import '../editor/note_editor.dart';
import '../notes_list/notes_list.dart';
import '../providers.dart';
import '../settings/settings_screen.dart';
import '../theme/app_theme.dart';
import '../trash/trash_screen.dart';
import '../widgets/sync_status_chip.dart';
import '../widgets/transfers_button.dart';
import '../widgets/note_info_button.dart';
import '../attachments/attachments_panel.dart';
import '../../update/update_service.dart';
import '../../app_version.dart';

/// Adaptive root: list + editor side-by-side on wide screens,
/// list -> editor navigation on phones.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});
  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> with WidgetsBindingObserver {
  final _searchFocus = FocusNode();
  bool _checkingUpdate = false;
  String? _notifiedVersion;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkUpdate());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(syncProvider).wakeUp();
      _checkUpdate();
    }
  }

  Future<void> _checkUpdate() async {
    if (!mounted || _checkingUpdate) return;
    final store = ref.read(storeProvider);
    if (store.getSetting('updates_auto') == 'false') return;
    final last = int.tryParse(store.getSetting('updates_last_check') ?? '') ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - last < const Duration(hours: 6).inMilliseconds) return;
    _checkingUpdate = true;
    store.setSetting('updates_last_check', '$now');
    try {
      final release = await UpdateService.fetchLatest().timeout(const Duration(seconds: 20));
      if (!mounted || store.getSetting('updates_auto') == 'false' || !UpdateService.isNewer(release.version, appVersion) || _notifiedVersion == release.version) return;
      _notifiedVersion = release.version;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        duration: const Duration(seconds: 12),
        content: Text('Доступна новая версия NoteVibe ${release.version}'),
        action: SnackBarAction(label: 'Открыть', onPressed: () => Navigator.push(context,
          MaterialPageRoute(builder: (_) => const SettingsScreen()))),
      ));
    } catch (_) {
      // A failed background check must not interrupt editing or offline use.
    } finally {
      _checkingUpdate = false;
    }
  }

  void _newNote(bool wide) {
    ref.read(searchQueryProvider.notifier).set('');
    final n = ref.read(storeProvider).createNote();
    _open(n, wide);
  }

  void _newVoiceNote(bool wide) {
    ref.read(searchQueryProvider.notifier).set('');
    final n = ref.read(storeProvider).createNote(kind: 'voice');
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

  void _bulkArchive(Set<String> ids) {
    ref.read(storeProvider).setArchived(ids, true);
    ref.read(selectionProvider.notifier).clear();
  }

  void _bulkImportant(Set<String> ids) {
    final store = ref.read(storeProvider);
    final allImportant = ids.every((id) => store.getNote(id)?.important ?? false);
    for (final id in ids) {
      store.setImportant(id, !allImportant);
    }
    ref.read(selectionProvider.notifier).clear();
  }

  Future<void> _bulkDelete(Set<String> ids) async {
    final store = ref.read(storeProvider);
    final toTrash = store.trashDays != 0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(toTrash ? 'В корзину (${ids.length})?' : 'Удалить заметки (${ids.length})?'),
        content: Text(toTrash
            ? 'Заметки попадут в корзину и удалятся автоматически по сроку из настроек.'
            : 'Заметки будут удалены на всех синхронизированных устройствах.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(toTrash ? 'В корзину' : 'Удалить')),
        ],
      ),
    );
    if (ok != true) return;
    final selectedNote = ref.read(selectedNoteProvider);
    store.removeNotes(ids);
    if (selectedNote != null && ids.contains(selectedNote)) {
      ref.read(selectedNoteProvider.notifier).select(null);
    }
    ref.read(selectionProvider.notifier).clear();
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= kWideLayout;
    final sync = ref.watch(syncProvider);
    final status = ref.watch(syncStatusProvider).value ?? sync.currentStatus;
    final selected = ref.watch(selectedNoteProvider);
    final selecting = ref.watch(selectionProvider);

    final actions = <Widget>[
      if (wide) ...[
      if (selecting == null)
        IconButton(
          tooltip: 'Выбрать заметки',
          icon: const Icon(Icons.checklist),
          onPressed: () => ref.read(selectionProvider.notifier).start(),
        ),
      IconButton(
        tooltip: 'Архив',
        icon: const Icon(Icons.archive_outlined),
        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ArchiveScreen())),
      ),
      IconButton(
        tooltip: 'Корзина',
        icon: const Icon(Icons.delete_outline),
        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TrashScreen())),
      ),
      const SizedBox(width: 8),
      ] else ...[
        SyncStatusChip(status: status, compact: true, onTap: () => _onStatusTap(status)),
        const TransfersButton(),
        PopupMenuButton<String>(
          tooltip: 'Меню',
          position: PopupMenuPosition.under,
          offset: const Offset(-8, 8),
          constraints: const BoxConstraints(minWidth: 224, maxWidth: 280),
          menuPadding: const EdgeInsets.all(8),
          color: Theme.of(context).cardTheme.color,
          surfaceTintColor: Colors.transparent,
          shadowColor: Colors.black.withValues(alpha: 0.16),
          elevation: 6,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
          popUpAnimationStyle: const AnimationStyle(
            duration: Duration(milliseconds: 280),
            reverseDuration: Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          ),
          onSelected: (value) {
            final Widget page = switch (value) {
              'archive' => const ArchiveScreen(),
              'trash' => const TrashScreen(),
              'devices' => const DevicesScreen(),
              _ => const SettingsScreen(),
            };
            Navigator.push(context, MaterialPageRoute(builder: (_) => page));
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'archive', child: _HomeMenuLabel(icon: Icons.archive_outlined, text: 'Архив')),
            PopupMenuItem(value: 'trash', child: _HomeMenuLabel(icon: Icons.delete_outline, text: 'Корзина')),
            PopupMenuItem(value: 'devices', child: _HomeMenuLabel(icon: Icons.devices_outlined, text: 'Устройства')),
            PopupMenuItem(value: 'settings', child: _HomeMenuLabel(icon: Icons.settings_outlined, text: 'Настройки')),
          ],
        ),
      ],
      if (wide) ...[
      SyncStatusChip(status: status, compact: !wide, onTap: () => _onStatusTap(status)),
      const TransfersButton(),
      const SizedBox(width: 8),
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
      ],
    ];

    final listPane = Column(children: [
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
                  ? _EmptyEditor(
                      onCreate: () => _newNote(true),
                      onCreateVoice: () => _newVoiceNote(true),
                    )
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
          appBar: PreferredSize(
            preferredSize: Size.fromHeight(kToolbarHeight + (selecting == null ? 60 : 0)),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 260),
              reverseDuration: const Duration(milliseconds: 200),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              child: selecting != null
              ? AppBar(
                  key: const ValueKey('selection'),
                  leading: IconButton(
                    tooltip: 'Отменить выбор',
                    icon: const Icon(Icons.close),
                    onPressed: () => ref.read(selectionProvider.notifier).clear(),
                  ),
                  title: Text('Выбрано: ${selecting.length}'),
                  actions: [
                    IconButton(
                      tooltip: selecting.isEmpty ? 'Нет выбранных' : 'В архив',
                      icon: const Icon(Icons.archive_outlined),
                      onPressed: selecting.isEmpty ? null : () => _bulkArchive(selecting),
                    ),
                    IconButton(
                      tooltip: selecting.isEmpty ? 'Нет выбранных' : 'Отметить важными',
                      icon: const Icon(Icons.star_outline),
                      onPressed: selecting.isEmpty ? null : () => _bulkImportant(selecting),
                    ),
                    IconButton(
                      tooltip: 'Переместить выбранные в корзину',
                      icon: const Icon(Icons.delete_sweep_outlined),
                      onPressed: selecting.isEmpty ? null : () => _bulkDelete(selecting),
                    ),
                    const SizedBox(width: 8),
                  ],
                )
              : AppBar(
                  key: const ValueKey('normal'),
                   title: const Text('NoteVibe'),
                   bottom: PreferredSize(
                     preferredSize: const Size.fromHeight(60),
                     child: Padding(
                       padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                       child: Align(
                         alignment: Alignment.centerLeft,
                         child: SizedBox(width: wide ? 328 : double.infinity, child: SearchField(focusNode: _searchFocus)),
                       ),
                     ),
                   ),
                   actions: actions,
                ),
            ),
          ),
          body: body,
          floatingActionButton: wide || selecting != null
              ? null
              : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
                  FloatingActionButton(
                    heroTag: 'voice',
                    tooltip: 'Голосовая заметка',
                    onPressed: () => _newVoiceNote(false),
                    child: const Icon(Icons.mic),
                  ),
                  const SizedBox(height: 12),
                  FloatingActionButton(
                    heroTag: 'note',
                    tooltip: 'Новая заметка',
                    onPressed: () => _newNote(false),
                    child: const Icon(Icons.add),
                  ),
                ]),
        ),
      ),
    );
  }
}

class _HomeMenuLabel extends StatelessWidget {
  final IconData icon;
  final String text;
  const _HomeMenuLabel({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) => Row(children: [
    Icon(icon, size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant),
    const SizedBox(width: 14),
    Text(text, style: Theme.of(context).textTheme.bodyLarge),
  ]);
}

class _EmptyEditor extends StatelessWidget {
  final VoidCallback onCreate;
  final VoidCallback onCreateVoice;
  const _EmptyEditor({required this.onCreate, required this.onCreateVoice});
  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.sticky_note_2_outlined, size: 64, color: s.outlineVariant),
        const SizedBox(height: 16),
        Text('Выберите заметку или создайте новую', style: TextStyle(color: s.outline)),
        const SizedBox(height: 16),
        Wrap(alignment: WrapAlignment.center, spacing: 12, runSpacing: 12, children: [
          FilledButton.icon(
            onPressed: onCreate,
            icon: const Icon(Icons.add),
            label: const Text('Новая заметка  (Ctrl+N)'),
          ),
          OutlinedButton.icon(
            onPressed: onCreateVoice,
            icon: const Icon(Icons.mic),
            label: const Text('Голосовая заметка'),
          ),
        ]),
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
    final note = ref.watch(storeProvider).getNote(noteId);
    ref.watch(storeChangesProvider);
    final important = note?.important ?? false;
    final archived = note?.archived ?? false;
    return Scaffold(
      appBar: AppBar(
        actions: [
          if (note != null) NoteInfoButton(createdAt: note.createdAt, updatedAt: note.updatedAt),
          IconButton(
            tooltip: 'Добавить вложения',
            icon: const Icon(Icons.attach_file),
            onPressed: () => addNoteAttachments(context, ref, noteId),
          ),
          SyncStatusChip(
            status: status,
            compact: true,
            onTap: status.state == SyncState.conflict ? () => openConflicts(context, noteId) : null,
          ),
          IconButton(
            tooltip: important ? 'Снять отметку «важное»' : 'Отметить как важное',
            iconSize: 26,
            icon: Icon(important ? Icons.star : Icons.star_outline,
                color: important ? Colors.amber.shade700 : null),
            onPressed: () => ref.read(storeProvider).setImportant(noteId, !important),
          ),
          IconButton(
            tooltip: archived ? 'Вернуть из архива' : 'В архив',
            iconSize: 26,
            icon: Icon(archived ? Icons.unarchive_outlined : Icons.archive_outlined),
            onPressed: () {
              ref.read(storeProvider).setArchived([noteId], !archived);
              Navigator.of(context).maybePop();
            },
          ),
          IconButton(
            tooltip: 'Переместить в корзину',
            iconSize: 26,
            icon: const Icon(Icons.delete_sweep_outlined),
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
