import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/note_store.dart';
import '../../domain/note.dart';
import '../conflicts/conflict_screen.dart';
import '../attachments/attachments_panel.dart';
import '../providers.dart';
import '../voice/voice_panel.dart';
import '../widgets/note_info_button.dart';
import '../widgets/reminder_button.dart';
import 'format_glyph.dart';
import 'code_dialog.dart';
import 'code_blocks.dart';
import '../theme/code_style.dart';
import '../widgets/overflow_title_hint.dart';
import 'dart:io';


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
  final _quillScroll = ScrollController();
  final _renderKey = GlobalKey<EditorState>();
  bool _caretPending = false;
  bool _hideCodeCaret = false;

  void _onEditorFocusChanged() {
    _updateCodeCaret();
  }

  void _updateCodeCaret() {
    if (!mounted) return;
    if (!_editorFocus.hasFocus) {
      if (!_hideCodeCaret) setState(() => _hideCodeCaret = true);
      return;
    }
    final position = _quill.selection.extentOffset;
    var offset = 0;
    var onCode = false;
    for (final op in _quill.document.toDelta().toJson()) {
      final insert = op['insert'];
      if (insert is Map && insert.containsKey(codeEmbedKey) && position >= offset && position <= offset + 1) {
        onCode = true;
        break;
      }
      offset += insert is String ? insert.length : 1;
      if (offset > position) break;
    }
    final hide = !_editorFocus.hasFocus || onCode;
    if (_hideCodeCaret != hide) setState(() => _hideCodeCaret = hide);
  }

  void _hideCaretForCode() {
    if (!mounted) return;
    if (!_hideCodeCaret) setState(() => _hideCodeCaret = true);
    _editorFocus.unfocus();
  }
  StreamSubscription<DocChange>? _docSub;
  StreamSubscription<void>? _storeSub;
  Timer? _saveTimer;
  bool _dirty = false;
  Note? _note;
  String? _saveError;
  late final AppServices _services;

  NoteStore get _store => ref.read(storeProvider);

  Future<void> _removeCode() async {
    final confirmed = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: const Text('Удалить весь код?'),
      content: const Text('Все блоки программного кода будут удалены. Обычный текст заметки останется.'),
      actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Отмена')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Удалить'))],
    ));
    if (confirmed != true || !mounted) return;
    final operations = expandCodeBlocks(_quill.document.toDelta().toJson());
    final kept = <Map<String, dynamic>>[];
    var pending = <Map<String, dynamic>>[];
    for (final op in operations) {
      final text = op['insert'];
      if (text is! String) { pending.add(Map<String, dynamic>.from(op)); continue; }
      var start = 0;
      for (var i = 0; i < text.length; i++) {
        if (text[i] != '\n') continue;
        pending.add({...op, 'insert': text.substring(start, i + 1)});
        if ((op['attributes'] as Map?)?['code-block'] == null) kept.addAll(pending);
        pending = [];
        start = i + 1;
      }
      if (start < text.length) pending.add({...op, 'insert': text.substring(start)});
    }
    kept.addAll(pending);
    if (kept.isEmpty) kept.add({'insert': '\n'});
    _quill.document = Document.fromJson(foldCodeBlocks(kept));
    _docSub?.cancel();
    _docSub = _quill.changes.listen((change) { if (change.source == ChangeSource.local) _onEdited(); });
    _quill.updateSelection(const TextSelection.collapsed(offset: 0), ChangeSource.silent);
    _onEdited();
    _save();
    setState(() {});
  }

  Future<void> _editCode() async {
    final selection = _quill.selection;
    final code = await editCode(context, '',
      highlight: _store.getSetting('code_highlight') != 'false',
      fontScale: ref.read(noteFontSizeProvider).scale);
    if (code == null || !mounted) return;
    var offset = selection.start.clamp(0, _quill.document.length - 1);
    final plain = _quill.document.toPlainText();
    // Keep an ordinary separator so adjacent blocks remain independent in the
    // standard persisted format, including when reopened by older clients.
    if (offset >= 2 && plain.substring(offset - 2, offset) == '\uFFFC\n') {
      _quill.replaceText(offset, 0, '\n', null);
      offset++;
    }
    if (offset > 0 && plain[offset - 1] != '\n') {
      _quill.replaceText(offset, 0, '\n', null);
      offset++;
    }
    _quill.replaceText(offset, 0, Embeddable(codeEmbedKey, {'source': code, 'id': UniqueKey().toString()}), null);
    // The embed occupies its own line; the next line is always ordinary text.
    final after = _quill.document.toPlainText();
    if (offset + 1 >= after.length || after[offset + 1] != '\n') {
      _quill.replaceText(offset + 1, 0, '\n', null);
    }
    if (offset + 2 >= _quill.document.length || _quill.document.toPlainText()[offset + 2] == '\uFFFC') {
      _quill.replaceText(offset + 2, 0, '\n', null);
    }
    _quill.formatText(offset + 1, 1, Attribute.clone(Attribute.codeBlock, null));
    _quill.updateSelection(TextSelection.collapsed(offset: offset + 2), ChangeSource.local);
    _quill.formatSelection(Attribute.clone(Attribute.codeBlock, null));
    _editorFocus.requestFocus();
    _onEdited();
    _save();
    setState(() {});
  }

  Future<void> _editEmbeddedCode(EmbedContext embed) async {
    final node = embed.node;
    final data = node.value.data as Map;
    final code = await editCode(context, data['source'] as String,
      highlight: _store.getSetting('code_highlight') != 'false', fontScale: ref.read(noteFontSizeProvider).scale);
    if (code == null || !mounted) return;
    final offset = _codeOffset(data['id']);
    if (offset == null) return;
    _quill.replaceText(offset, 1, Embeddable(codeEmbedKey, {'source': code, 'id': data['id']}),
      TextSelection.collapsed(offset: offset));
    _onEdited();
    _save();
    setState(() {});
  }

  Future<void> _deleteEmbeddedCode(EmbedContext embed) async {
    final id = (embed.node.value.data as Map)['id'];
    final confirmed = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: const Text('Удалить блок кода?'),
      content: const Text('Остальные блоки и обычный текст останутся.'),
      actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Отмена')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Удалить'))]));
    if (confirmed != true || !mounted) return;
    final offset = _codeOffset(id);
    if (offset == null) return;
    final length = offset + 2 < _quill.document.length ? 2 : 1;
    _quill.replaceText(offset, length, '', TextSelection.collapsed(offset: offset));
    _onEdited();
    _save();
    setState(() {});
  }

  int? _codeOffset(dynamic id) {
    var offset = 0;
    for (final op in _quill.document.toDelta().toJson()) {
      final insert = op['insert'];
      if (insert is Map && insert[codeEmbedKey] is Map && insert[codeEmbedKey]['id'] == id) return offset;
      offset += insert is String ? insert.length : 1;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _services = ref.read(servicesProvider);
    WidgetsBinding.instance.addObserver(this);
    _editorFocus.addListener(_onEditorFocusChanged);
    _quill = QuillController.basic();
    _load();
    _title.addListener(_onEdited);
    _storeSub = _store.changes.listen((_) => _onStoreChanged());
    _services.pendingEditors.add(_flushForShutdown);
  }

  void _load() {
    final n = _store.getNote(widget.noteId);
    _note = n;
    _docSub?.cancel();
    final oldQuill = _quill;
    Document doc;
    try {
      doc = Document.fromJson(foldCodeBlocks(jsonDecode(n?.content ?? emptyDeltaJson) as List));
    } catch (_) {
      doc = Document()..insert(0, n?.plainText ?? '');
    }
    _quill = QuillController(
      document: doc,
      selection: const TextSelection.collapsed(offset: 0),
    );
    _docSub = _quill.changes.listen((c) {
      if (c.source == ChangeSource.local) {
        _onEdited();
        if (c.change.toList().any((op) => op.isInsert && op.data is String && (op.data as String).contains('\n'))) {
          final controller = _quill;
          scheduleMicrotask(() {
            if (!mounted || !identical(controller, _quill)) return;
            if (_quill.getSelectionStyle().attributes[Attribute.list.key]?.value == 'checked') {
              _quill.formatSelection(Attribute.unchecked);
            }
          });
        }
      }
    });
    _quill.addListener(_keepCaretVisible);
    _quill.addListener(_updateCodeCaret);
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

  @override
  void didChangeMetrics() => _keepCaretVisible();

  void _keepCaretVisible() {
    if (!mounted || !_editorFocus.hasFocus || _caretPending || _store.getSetting('keep_input_visible') == 'false') return;
    _caretPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _caretPending = false;
      if (!mounted || !_editorFocus.hasFocus || !_scroll.hasClients) return;
      final render = _renderKey.currentState?.renderEditor;
      if (render == null || !render.attached || !_quill.selection.isValid) return;
      final rect = render.getLocalRectForCaret(TextPosition(offset: _quill.selection.extentOffset));
      final origin = render.localToGlobal(Offset.zero);
      final top = origin.dy + rect.top;
      final bottom = origin.dy + rect.bottom;
      final viewport = _scroll.position.context.storageContext.findRenderObject();
      if (viewport is! RenderBox || !viewport.hasSize) return;
      final viewportTop = viewport.localToGlobal(Offset.zero).dy;
      final viewportBottom = viewportTop + viewport.size.height - 24;
      final delta = bottom > viewportBottom ? bottom - viewportBottom : top < viewportTop + 16 ? top - viewportTop - 16 : 0.0;
      if (delta.abs() > 1) {
        _scroll.jumpTo((_scroll.offset + delta).clamp(_scroll.position.minScrollExtent, _scroll.position.maxScrollExtent));
      }
    });
  }

  void _flushForShutdown() {
    _save();
    if (_dirty) throw StateError('Редактор не смог сохранить изменения');
  }

  void _save() {
    _saveTimer?.cancel();
    if (!_dirty) return;
    try {
      final operations = expandCodeBlocks(_quill.document.toDelta().toJson());
      final content = jsonEncode(operations);
      final plain = operations.map((op) => op['insert'] is String ? op['insert'] as String : '\uFFFC').join();
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
    _services.pendingEditors.remove(_flushForShutdown);
    _save();
    WidgetsBinding.instance.removeObserver(this);
    _saveTimer?.cancel();
    _docSub?.cancel();
    _storeSub?.cancel();
    _quill.dispose();
    _editorFocus.removeListener(_onEditorFocusChanged);
    _title.dispose();
    _editorFocus.dispose();
    _scroll.dispose();
    _quillScroll.dispose();
    super.dispose();
  }

  Future<void> confirmDelete() async {
    final store = ref.read(storeProvider);
    final toTrash = store.trashDays != 0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(toTrash ? 'Переместить в корзину?' : 'Удалить заметку?'),
        content: Text(toTrash
            ? 'Заметка попадёт в корзину и удалится автоматически по сроку из настроек.'
            : 'Заметка будет удалена на всех синхронизированных устройствах.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(toTrash ? 'В корзину' : 'Удалить')),
        ],
      ),
    );
    if (ok != true) return;
    _saveTimer?.cancel();
    _dirty = false;
    store.removeNotes([widget.noteId]);
    widget.onDeleted?.call();
  }

  @override
  Widget build(BuildContext context) {
    final note = _note;
    if (note == null || note.deleted) {
      return const Center(child: Text('Заметка удалена'));
    }
    final hasConflict = _store.conflictsFor(widget.noteId).isNotEmpty;
    final codeLines = noteLines(jsonEncode(expandCodeBlocks(_quill.document.toDelta().toJson())), '')
      .where((line) => line.attributes['code-block'] != null).toList();

    final toolbar = FormatToolbar(controller: _quill, large: widget.compact,
      onRemoveCode: codeLines.isNotEmpty ? _removeCode : null,
      onCode: _store.getSetting('code_blocks') != 'false' ? _editCode : null);

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
                Expanded(child: note.isVoice ? const SizedBox.shrink() : toolbar),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Добавить вложения',
                  icon: const Icon(Icons.attach_file),
                  onPressed: () => addNoteAttachments(context, ref, widget.noteId),
                ),
                NoteInfoButton(createdAt: note.createdAt, updatedAt: note.updatedAt,
                  content: jsonEncode(expandCodeBlocks(_quill.document.toDelta().toJson()))),
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
                  tooltip: 'Переместить в корзину',
                  icon: const Icon(Icons.delete_sweep_outlined),
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
              padding: EdgeInsets.symmetric(horizontal: widget.compact ? 12 : 24, vertical: 12),
              children: [
                Row(crossAxisAlignment: CrossAxisAlignment.center, children: [Expanded(child: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _title,
                  builder: (context, value, _) => EditableTitleHint(
                    title: value.text,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      fontSize: Theme.of(context).textTheme.headlineSmall!.fontSize! * ref.watch(noteFontSizeProvider).scale),
                    child: TextField(
                  controller: _title,
                   style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                     fontWeight: FontWeight.w700,
                     fontSize: Theme.of(context).textTheme.headlineSmall!.fontSize! * ref.watch(noteFontSizeProvider).scale,
                   ),
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
                )))),
                 if (Platform.isAndroid) ReminderButton(noteId: widget.noteId, title: _title.text, compact: true),
                ]),
                 const SizedBox(height: 10),
                 if (note.isVoice)
                  VoicePanel(noteId: widget.noteId)
                else
                   Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                   QuillEditor(
                    controller: _quill,
                    focusNode: _editorFocus,
                    scrollController: _quillScroll,
                      config: QuillEditorConfig(
                        showCursor: !_hideCodeCaret,
                        embedBuilders: [CodeBlockBuilder(
                          scale: ref.watch(noteFontSizeProvider).scale,
                          highlight: _store.getSetting('code_highlight') != 'false',
                          onEdit: _editEmbeddedCode, onDelete: _deleteEmbeddedCode,
                          onToggle: _hideCaretForCode)],
                       showCodeBlockLineNumbers: false,
                      scrollable: false,
                      editorKey: _renderKey,
                      textSpanBuilder: (context, node, offset, text, style, recognizer) {
                        var code = false;
                        Node? current = node;
                        while (current != null) {
                          if (current.style.attributes[Attribute.codeBlock.key]?.value != null) { code = true; break; }
                          current = current.parent;
                        }
                        if (code && _store.getSetting('code_highlight') != 'false') {
                          return highlightedCode(context, text, style);
                        }
                        return TextSpan(text: text, style: style, recognizer: recognizer);
                      },
                      customStyleBuilder: (attribute) => attribute.key == Attribute.list.key && attribute.value == 'checked'
                        ? TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5), decoration: TextDecoration.lineThrough)
                        : const TextStyle(),
                      placeholder: 'Начните писать…',
                      padding: const EdgeInsets.only(bottom: 120),
                       customStyles: _styles(context),
                     ),
                   ),
                   ]),
                const SizedBox(height: 16),
                AttachmentsPanel(noteId: widget.noteId, skipAudio: note.isVoice),
              ],
            ),
          ),
          if (widget.compact && !note.isVoice)
            SafeArea(
              top: false,
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
                child: toolbar,
              ),
            ),
        ],
      ),
    );
  }

  DefaultStyles _styles(BuildContext context) {
    final scale = ref.watch(noteFontSizeProvider).scale;
    final base = Theme.of(context).textTheme.bodyLarge!.copyWith(fontSize: 17 * scale, height: 1.5);
    final defaults = DefaultStyles.getInstance(context);
    DefaultTextBlockStyle? scaled(DefaultTextBlockStyle? style) => style?.copyWith(
      style: style.style.copyWith(fontSize: (style.style.fontSize ?? 17) * scale));
    return DefaultStyles(
      lists: defaults.lists?.copyWith(style: base, checkboxUIBuilder: _StableCheckboxBuilder(scale)),
      h1: scaled(defaults.h1), h2: scaled(defaults.h2), h3: scaled(defaults.h3),
      h4: scaled(defaults.h4), h5: scaled(defaults.h5), h6: scaled(defaults.h6),
       quote: scaled(defaults.quote),
       code: DefaultTextBlockStyle(
         TextStyle(fontFamily: 'monospace', fontSize: 14 * scale, height: 1.45,
           color: Theme.of(context).colorScheme.onSurface),
         const HorizontalSpacing(6, 6), const VerticalSpacing(6, 6), VerticalSpacing.zero,
         codeDecoration(context),
       ),
      indent: scaled(defaults.indent), align: scaled(defaults.align),
      leading: scaled(defaults.leading), placeHolder: scaled(defaults.placeHolder),
      sizeSmall: TextStyle(fontSize: 12 * scale),
      sizeLarge: TextStyle(fontSize: 22 * scale),
      sizeHuge: TextStyle(fontSize: 28 * scale),
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

// Avoid ink animations migrating between list blocks when Quill rebuilds them.
class _StableCheckboxBuilder extends QuillCheckboxBuilder {
  final double scale;
  _StableCheckboxBuilder(this.scale);
  @override
  Widget build({required BuildContext context, required bool isChecked, required ValueChanged<bool> onChanged}) =>
    Semantics(checked: isChecked, label: 'Пункт списка', onTap: () => onChanged(!isChecked), child: GestureDetector(
      behavior: HitTestBehavior.opaque, onTap: () => onChanged(!isChecked),
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Icon(isChecked ? Icons.check_box : Icons.check_box_outline_blank, size: 22 * scale,
          color: isChecked ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.outline)),
    ));
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
  final VoidCallback? onCode;
  final VoidCallback? onRemoveCode;
  const FormatToolbar({super.key, required this.controller, this.large = false, this.onCode, this.onRemoveCode});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const size = 24.0;
    final factor = large ? 40 / size : 32 / size;
    final buttonSize = large ? 40.0 : 32.0;
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(12));
    final iconTheme = QuillIconTheme(
      iconButtonSelectedData: IconButtonData(
        iconSize: size,
        style: IconButton.styleFrom(minimumSize: Size.square(buttonSize), padding: EdgeInsets.zero, backgroundColor: scheme.primaryContainer, foregroundColor: scheme.onPrimaryContainer, shape: shape),
      ),
      iconButtonUnselectedData: IconButtonData(
        iconSize: size,
        style: IconButton.styleFrom(minimumSize: Size.square(buttonSize), padding: EdgeInsets.zero, foregroundColor: scheme.onSurfaceVariant, shape: shape),
      ),
    );
    final opts = QuillToolbarToggleStyleButtonOptions(iconSize: size, iconButtonFactor: factor, iconTheme: iconTheme);
    final divider = SizedBox(
      height: size,
      child: VerticalDivider(width: large ? 10 : 12, color: Theme.of(context).colorScheme.outlineVariant),
    );
    return Material(
      color: Theme.of(context).cardTheme.color ?? scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
        child: LayoutBuilder(
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
                options: opts.copyWithTooltip('Жирный (Ctrl+B)', Icons.format_bold, (o,e) => _command(context, 'bold', 'Жирный (Ctrl+B)', e.onPressed, selected: e.isToggled)),
              ),
              QuillToolbarToggleStyleButton(
                controller: controller,
                attribute: Attribute.italic,
                options: opts.copyWithTooltip('Курсив (Ctrl+I)', Icons.format_italic, (o,e) => _command(context, 'italic', 'Курсив (Ctrl+I)', e.onPressed, selected: e.isToggled)),
              ),
              QuillToolbarToggleStyleButton(
                controller: controller,
                attribute: Attribute.underline,
                options: opts.copyWithTooltip('Подчёркнутый (Ctrl+U)', Icons.format_underline, (o,e) => _command(context, 'underline', 'Подчёркнутый (Ctrl+U)', e.onPressed, selected: e.isToggled)),
              ),
              divider,
              if (onCode != null) IconButton(
                tooltip: 'Блок кода', onPressed: onCode, icon: const Icon(Icons.code, size: size),
                style: IconButton.styleFrom(minimumSize: Size.square(buttonSize),
                  padding: EdgeInsets.zero, foregroundColor: scheme.onSurfaceVariant, shape: shape)),
              if (onRemoveCode != null) IconButton(
                tooltip: 'Удалить весь код', onPressed: onRemoveCode,
                icon: const Icon(Icons.code_off, size: size),
                style: IconButton.styleFrom(minimumSize: Size.square(buttonSize),
                  padding: EdgeInsets.zero, foregroundColor: scheme.onSurfaceVariant, shape: shape)),
              QuillToolbarToggleCheckListButton(
                controller: controller,
                options: QuillToolbarToggleCheckListButtonOptions(
                  iconSize: size,
                  iconButtonFactor: factor,
                  tooltip: 'Чек-лист',
                   iconData: Icons.checklist,
                   iconTheme: iconTheme,
                    childBuilder: (dynamic o, dynamic e) => _command(context, 'check', 'Чек-лист', e.onPressed as VoidCallback?, selected: e.isToggled as bool),
                ),
              ),
              QuillToolbarToggleStyleButton(
                controller: controller,
                attribute: Attribute.ul,
                options: opts.copyWithTooltip('Список', Icons.format_list_bulleted, (o,e) => _command(context, 'list', 'Список', e.onPressed, selected: e.isToggled)),
              ),
              divider,
              _colorButton(context, background: false),
              _colorButton(context, background: true),
              divider,
              QuillToolbarHistoryButton(
                controller: controller,
                isUndo: true,
                options: QuillToolbarHistoryButtonOptions(
                    iconSize: size, iconButtonFactor: factor, iconTheme: iconTheme, tooltip: 'Отменить',
                     childBuilder: (dynamic o, dynamic e) => _command(context, 'undo', 'Отменить', e.onPressed as VoidCallback?)),
              ),
              QuillToolbarHistoryButton(
                controller: controller,
                isUndo: false,
                options: QuillToolbarHistoryButtonOptions(
                    iconSize: size, iconButtonFactor: factor, iconTheme: iconTheme, tooltip: 'Повторить',
                     childBuilder: (dynamic o, dynamic e) => _command(context, 'redo', 'Повторить', e.onPressed as VoidCallback?)),
              ),
            ],
          ),
        ),
      ),
        ),
      ),
    );
  }

  Widget _command(BuildContext context, String glyph, String tooltip, VoidCallback? onPressed, {bool selected = false}) => IconButton(
    tooltip: tooltip,
    style: IconButton.styleFrom(
      fixedSize: Size.square(large ? 40 : 32), minimumSize: Size.square(large ? 40 : 32),
      padding: EdgeInsets.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      foregroundColor: selected ? Theme.of(context).colorScheme.onPrimaryContainer : Theme.of(context).colorScheme.onSurfaceVariant,
      backgroundColor: selected ? Theme.of(context).colorScheme.primaryContainer : Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    icon: FormatGlyph(glyph), onPressed: onPressed,
  );

  Widget _colorButton(BuildContext context, {required bool background}) => ListenableBuilder(
    listenable: controller, builder: (context, _) {
    final value = controller.getSelectionStyle().attributes[background ? 'background' : 'color']?.value;
    final hex = value is String ? int.tryParse(value.replaceFirst('#', ''), radix: 16) : null;
    final active = hex == null ? Theme.of(context).colorScheme.onSurfaceVariant : Color(hex | 0xFF000000);
    return IconButton(
    style: IconButton.styleFrom(
      fixedSize: Size.square(large ? 40 : 32),
      minimumSize: Size.square(large ? 40 : 32),
      padding: EdgeInsets.zero,
      foregroundColor: active,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    tooltip: background ? 'Цвет выделения' : 'Цвет текста',
    iconSize: 24,
    icon: FormatGlyph(background ? 'highlight' : 'color'),
    onPressed: () async {
      final selection = controller.selection;
      final picked = await showDialog<String>(context: context, builder: (c) => SimpleDialog(
        title: Text(background ? 'Цвет выделения' : 'Цвет текста'),
        children: [
          Padding(padding: const EdgeInsets.all(16), child: Wrap(spacing: 12, runSpacing: 12, children: [
            for (final entry in const <String, String>{
              '#D32F2F': 'Красный', '#EF6C00': 'Оранжевый', '#FBC02D': 'Жёлтый',
              '#388E3C': 'Зелёный', '#1976D2': 'Синий', '#7B1FA2': 'Фиолетовый',
              '#000000': 'Чёрный', '#FFFFFF': 'Белый',
            }.entries)
              IconButton.filledTonal(
                tooltip: entry.value,
                onPressed: () => Navigator.pop(c, entry.key),
                icon: Container(width: 28, height: 28, decoration: BoxDecoration(
                  color: Color(int.parse(entry.key.substring(1), radix: 16) | 0xFF000000),
                  shape: BoxShape.circle, border: Border.all(color: Theme.of(c).colorScheme.outline))),
              ),
          ])),
          SimpleDialogOption(onPressed: () => Navigator.pop(c, ''), child: const Text('Сбросить цвет')),
        ],
      ));
      if (picked == null || !context.mounted) return;
      controller.updateSelection(selection, ChangeSource.local);
      controller.formatSelection(Attribute.fromKeyValue(background ? 'background' : 'color', picked.isEmpty ? null : picked));
    },
  ); });
}

extension on QuillToolbarToggleStyleButtonOptions {
  QuillToolbarToggleStyleButtonOptions copyWithTooltip(String tooltip, IconData icon,
      Widget Function(QuillToolbarToggleStyleButtonOptions, QuillToolbarToggleStyleButtonExtraOptions) builder) =>
      QuillToolbarToggleStyleButtonOptions(
        iconSize: iconSize,
        iconButtonFactor: iconButtonFactor,
        iconTheme: iconTheme,
        tooltip: tooltip,
        iconData: icon,
        childBuilder: (dynamic o, dynamic e) => builder(o as QuillToolbarToggleStyleButtonOptions, e as QuillToolbarToggleStyleButtonExtraOptions),
      );
}
