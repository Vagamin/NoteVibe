import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/note_store.dart';
import '../../domain/note.dart';
import '../conflicts/conflict_screen.dart';
import '../attachments/attachments_panel.dart';
import '../providers.dart';

final _dateFmt = DateFormat('d MMM yyyy, HH:mm', 'ru');

/// Editor for a single note with debounced autosave.
///
/// Changes are written to SQLite 500 ms after the last keystroke, on leaving
/// the note, and when the app goes to background, so nothing is lost if the
/// app is killed.
class NoteEditor extends ConsumerStatefulWidget {
  final String noteId;
  final bool compact;
  final VoidCallback? onDeleted;
  const NoteEditor({super.key, required this.noteId, this.compact = false, this.onDeleted});

  @override
  ConsumerState<NoteEditor> createState() => NoteEditorState();
}

class NoteEditorState extends ConsumerState<NoteEditor> with WidgetsBindingObserver {
  late QuillController _quill;
  final _title = TextEditingController();
  final _editorFocus = FocusNode();
  final _scroll = ScrollController();
  StreamSubscription<DocChange>? _docSub;
  StreamSubscription<void>? _storeSub;
  Timer? _saveTimer;
  bool _dirty = false;
  Note? _note;
  String? _saveError;

  NoteStore get _store => ref.read(storeProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _quill = QuillController.basic();
    _load();
    _title.addListener(_onEdited);
    _storeSub = _store.changes.listen((_) => _onStoreChanged());
  }

  void _load() {
    final n = _store.getNote(widget.noteId);
    _note = n;
    _docSub?.cancel();
    final oldQuill = _quill;
    Document doc;
    try {
      doc = Document.fromJson(jsonDecode(n?.content ?? emptyDeltaJson) as List);
    } catch (_) {
      doc = Document()..insert(0, n?.plainText ?? '');
    }
    _quill = QuillController(
      document: doc,
      selection: const TextSelection.collapsed(offset: 0),
    );
    _docSub = _quill.changes.listen((c) {
      if (c.source == ChangeSource.local) _onEdited();
    });
    if (!identical(oldQuill, _quill)) oldQuill.dispose();
    _title.removeListener(_onEdited);
    _title.text = n?.title ?? '';
    _title.addListener(_onEdited);
    _dirty = false;
  }

  /// A remote sync or conflict resolution changed this note.
  void _onStoreChanged() {
    if (!mounted) return;
    final fresh = _store.getNote(widget.noteId);
    if (fresh == null) return;
    final cur = _note;
    final contentChanged = cur == null ||
        fresh.content != cur.content ||
        fresh.title != cur.title ||
        fresh.deleted != cur.deleted;
    if (contentChanged && !_dirty) {
      // Safe to reload: user has no unsaved edits.
      final sel = _quill.selection;
      setState(_load);
      final len = _quill.document.length - 1;
      _quill.updateSelection(
        TextSelection.collapsed(offset: sel.baseOffset.clamp(0, len)),
        ChangeSource.silent,
      );
    } else {
      setState(() => _note = fresh.copyWith(content: cur?.content, title: cur?.title));
    }
  }

  void _onEdited() {
    _dirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), _save);
  }

  void _save() {
    _saveTimer?.cancel();
    if (!_dirty) return;
    try {
      final content = jsonEncode(_quill.document.toDelta().toJson());
      final plain = _quill.document.toPlainText();
      final updated = _store.updateNote(widget.noteId,
          title: _title.text, content: content, plainText: plain);
      _dirty = false;
      if (updated != null) _note = updated;
      if (_saveError != null && mounted) setState(() => _saveError = null);
    } catch (e) {
      if (mounted) setState(() => _saveError = 'Не удалось сохранить: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _save();
  }

  @override
  void dispose() {
    _save();
    WidgetsBinding.instance.removeObserver(this);
    _saveTimer?.cancel();
    _docSub?.cancel();
    _storeSub?.cancel();
    _quill.dispose();
    _title.dispose();
    _editorFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> confirmDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Удалить заметку?'),
        content: const Text('Заметка будет удалена на всех синхронизированных устройствах.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Удалить')),
        ],
      ),
    );
    if (ok != true) return;
    _saveTimer?.cancel();
    _dirty = false;
    _store.deleteNote(widget.noteId);
    widget.onDeleted?.call();
  }

  @override
  Widget build(BuildContext context) {
    final note = _note;
    final scheme = Theme.of(context).colorScheme;
    if (note == null || note.deleted) {
      return const Center(child: Text('Заметка удалена'));
    }
    final hasConflict = _store.conflictsFor(widget.noteId).isNotEmpty;

    final toolbar = FormatToolbar(controller: _quill, large: widget.compact);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
      },
      child: Column(
        children: [
          if (!widget.compact)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 16, 0),
              child: Row(children: [
                Expanded(child: toolbar),
                IconButton(
                  tooltip: note.important ? 'Снять отметку «важное»' : 'Отметить как важное',
                  icon: Icon(note.important ? Icons.star : Icons.star_outline,
                      color: note.important ? Colors.amber.shade700 : null),
                  onPressed: () => _store.setImportant(widget.noteId, !note.important),
                ),
                IconButton(
                  tooltip: note.archived ? 'Вернуть из архива' : 'В архив',
                  icon: Icon(note.archived ? Icons.unarchive_outlined : Icons.archive_outlined),
                  onPressed: () => _store.setArchived([widget.noteId], !note.archived),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: confirmDelete,
                ),
              ]),
            ),
          if (hasConflict)
            _ConflictBanner(onOpen: () => openConflicts(context, widget.noteId)),
          if (_saveError != null)
            MaterialBanner(
              content: Text(_saveError!),
              actions: [TextButton(onPressed: _save, child: const Text('Повторить'))],
            ),
          Expanded(
            child: ListView(
              controller: _scroll,
              padding: EdgeInsets.symmetric(horizontal: widget.compact ? 20 : 32, vertical: 12),
              children: [
                TextField(
                  controller: _title,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                  decoration: const InputDecoration(
                    hintText: 'Заголовок',
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    filled: false,
                    contentPadding: EdgeInsets.zero,
                  ),
                  textInputAction: TextInputAction.next,
                  onSubmitted: (_) => _editorFocus.requestFocus(),
                ),
                const SizedBox(height: 4),
                Text(
                  'Создано ${_dateFmt.format(note.createdAt)}  ·  Изменено ${_dateFmt.format(note.updatedAt)}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.outline),
                ),
                const SizedBox(height: 16),
                QuillEditor(
                  controller: _quill,
                  focusNode: _editorFocus,
                  scrollController: ScrollController(),
                  config: QuillEditorConfig(
                    scrollable: false,
                    placeholder: 'Начните писать…',
                    padding: const EdgeInsets.only(bottom: 120),
                    customStyles: _styles(context),
                  ),
                ),
                const SizedBox(height: 16),
                AttachmentsPanel(noteId: widget.noteId),
              ],
            ),
          ),
          if (widget.compact)
            SafeArea(
              top: false,
              child: Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).cardTheme.color,
                  border: Border(top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5))),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: toolbar,
              ),
            ),
        ],
      ),
    );
  }

  DefaultStyles _styles(BuildContext context) {
    final base = Theme.of(context).textTheme.bodyLarge!.copyWith(fontSize: 17, height: 1.5);
    return DefaultStyles(
      paragraph: DefaultTextBlockStyle(
        base,
        HorizontalSpacing.zero,
        const VerticalSpacing(2, 2),
        VerticalSpacing.zero,
        null,
      ),
    );
  }
}

class _ConflictBanner extends StatelessWidget {
  final VoidCallback onOpen;
  const _ConflictBanner({required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: s.errorContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(Icons.call_split, color: s.onErrorContainer),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Заметку изменили на двух устройствах одновременно.',
                style: TextStyle(color: s.onErrorContainer)),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: onOpen, child: const Text('Разрешить')),
            ),
          ]),
        ),
      ]),
    );
  }
}

/// Bold / italic / underline / checklist / undo / redo. Large targets on phones.
class FormatToolbar extends StatelessWidget {
  final QuillController controller;
  final bool large;
  const FormatToolbar({super.key, required this.controller, this.large = false});

  @override
  Widget build(BuildContext context) {
    final size = large ? 22.0 : 16.0;
    final factor = large ? 1.5 : 1.25;
    final opts = QuillToolbarToggleStyleButtonOptions(iconSize: size, iconButtonFactor: factor);
    final divider = SizedBox(
      height: size,
      child: VerticalDivider(width: large ? 10 : 12, color: Theme.of(context).colorScheme.outlineVariant),
    );
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: constraints.maxWidth),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              QuillToolbarToggleStyleButton(
                controller: controller,
                attribute: Attribute.bold,
                options: opts.copyWithTooltip('Жирный (Ctrl+B)', Icons.format_bold),
              ),
              QuillToolbarToggleStyleButton(
                controller: controller,
                attribute: Attribute.italic,
                options: opts.copyWithTooltip('Курсив (Ctrl+I)', Icons.format_italic),
              ),
              QuillToolbarToggleStyleButton(
                controller: controller,
                attribute: Attribute.underline,
                options: opts.copyWithTooltip('Подчёркнутый (Ctrl+U)', Icons.format_underline),
              ),
              divider,
              QuillToolbarToggleCheckListButton(
                controller: controller,
                options: QuillToolbarToggleCheckListButtonOptions(
                  iconSize: size,
                  iconButtonFactor: factor,
                  tooltip: 'Чек-лист',
                  iconData: Icons.checklist,
                ),
              ),
              QuillToolbarToggleStyleButton(
                controller: controller,
                attribute: Attribute.ul,
                options: opts.copyWithTooltip('Список', Icons.format_list_bulleted),
              ),
              divider,
              QuillToolbarHistoryButton(
                controller: controller,
                isUndo: true,
                options: QuillToolbarHistoryButtonOptions(
                    iconSize: size, iconButtonFactor: factor, tooltip: 'Отменить'),
              ),
              QuillToolbarHistoryButton(
                controller: controller,
                isUndo: false,
                options: QuillToolbarHistoryButtonOptions(
                    iconSize: size, iconButtonFactor: factor, tooltip: 'Повторить'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

extension on QuillToolbarToggleStyleButtonOptions {
  QuillToolbarToggleStyleButtonOptions copyWithTooltip(String tooltip, IconData icon) =>
      QuillToolbarToggleStyleButtonOptions(
        iconSize: iconSize,
        iconButtonFactor: iconButtonFactor,
        tooltip: tooltip,
        iconData: icon,
      );
}
