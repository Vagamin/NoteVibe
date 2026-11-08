import '../widgets/rounded_popup_menu_item.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';

import 'code_dialog.dart';

const codeEmbedKey = 'notevibe-code';

String codeBlockStateKey(String source, int occurrence) => '${sha256.convert(utf8.encode(source))}:$occurrence';

/// Presentation-only embeds. Persisted documents keep standard Quill code lines.
List<Map<String, dynamic>> expandCodeBlocks(List<dynamic> ops) {
  final result = <Map<String, dynamic>>[];
  var skipNewline = false;
  for (final raw in ops) {
    final op = Map<String, dynamic>.from(raw as Map);
    final insert = op['insert'];
    if (insert is Map && insert.containsKey(codeEmbedKey)) {
      final code = (insert[codeEmbedKey] as Map)['source'] as String;
      final lines = code.split('\n');
      for (var i = 0; i < lines.length; i++) {
        if (i == lines.length - 1 && lines[i].isEmpty) break;
        if (lines[i].isNotEmpty) result.add({'insert': lines[i]});
        result.add({'insert': '\n', 'attributes': {'code-block': true}});
      }
      if (code.isEmpty) result.add({'insert': '\n', 'attributes': {'code-block': true}});
      skipNewline = true;
    } else if (skipNewline && insert is String && insert.startsWith('\n')) {
      skipNewline = false;
      if (insert.length > 1) result.add({...op, 'insert': insert.substring(1)});
    } else {
      skipNewline = false;
      result.add(op);
    }
  }
  return result.isEmpty ? [{'insert': '\n'}] : result;
}

List<Map<String, dynamic>> foldCodeBlocks(List<dynamic> ops) {
  final result = <Map<String, dynamic>>[];
  var pending = <Map<String, dynamic>>[];
  final code = StringBuffer();
  final occurrences = <String, int>{};
  void flush() {
    if (code.isEmpty) return;
    final source = code.toString();
    final occurrence = occurrences.update(source, (value) => value + 1, ifAbsent: () => 0);
    result.add({'insert': {codeEmbedKey: {'source': source, 'id': codeBlockStateKey(source, occurrence)}}});
    result.add({'insert': '\n'});
    code.clear();
  }
  for (final raw in ops) {
    final op = Map<String, dynamic>.from(raw as Map);
    final text = op['insert'];
    if (text is! String) { flush(); result.addAll(pending); pending = []; result.add(op); continue; }
    // A Quill operation often contains thousands of complete lines. Keep it
    // whole instead of allocating a map and substring for every single line.
    if (pending.isEmpty && text.endsWith('\n')) {
      if ((op['attributes'] as Map?)?['code-block'] != null) {
        code.write(text);
      } else {
        flush();
        result.add(op);
      }
      continue;
    }
    var start = 0;
    for (var i = 0; i < text.length; i++) {
      if (text[i] != '\n') continue;
      pending.add({...op, 'insert': text.substring(start, i + 1)});
      if ((op['attributes'] as Map?)?['code-block'] != null) {
        for (final part in pending) { code.write(part['insert']); }
      } else {
        flush(); result.addAll(pending);
      }
      pending = [];
      start = i + 1;
    }
    if (start < text.length) pending.add({...op, 'insert': text.substring(start)});
  }
  flush(); result.addAll(pending);
  return result;
}

class CodeBlockBuilder extends EmbedBuilder {
  final double scale;
  final bool highlight;
  final Future<void> Function(EmbedContext) onEdit;
  final Future<void> Function(EmbedContext) onDelete;
  final VoidCallback onToggle;
  final ValueChanged<bool>? onPointerInteraction;
  final bool Function(String)? isCollapsed;
  final void Function(String, bool)? onCollapsedChanged;
  const CodeBlockBuilder({required this.scale, required this.highlight, required this.onEdit, required this.onDelete, required this.onToggle,
    this.isCollapsed, this.onCollapsedChanged, this.onPointerInteraction});
  @override
  String get key => codeEmbedKey;
  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final data = embedContext.node.value.data as Map;
    return Listener(
      onPointerDown: (_) => onPointerInteraction?.call(true),
      onPointerUp: (_) => WidgetsBinding.instance.addPostFrameCallback((_) => onPointerInteraction?.call(false)),
      onPointerCancel: (_) => onPointerInteraction?.call(false),
      child: _CodeBlock(key: ValueKey(data['id']), source: data['source'] as String,
      initiallyCollapsed: isCollapsed?.call(data['id'] as String) ?? false,
      onCollapsedChanged: (value) => onCollapsedChanged?.call(data['id'] as String, value),
      scale: scale, highlight: highlight, onEdit: () => onEdit(embedContext), onDelete: () => onDelete(embedContext), onToggle: onToggle));
  }
}

class _CodeBlock extends StatefulWidget {
  final String source;
  final double scale;
  final bool highlight;
  final VoidCallback onEdit, onDelete, onToggle;
  final bool initiallyCollapsed;
  final ValueChanged<bool> onCollapsedChanged;
  const _CodeBlock({super.key, required this.source, required this.scale, required this.highlight, required this.onEdit, required this.onDelete, required this.onToggle,
    required this.initiallyCollapsed, required this.onCollapsedChanged});
  @override
  State<_CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<_CodeBlock> {
  late bool collapsed = widget.initiallyCollapsed;
  Widget? _body;
  String? _language;
  @override
  void didUpdateWidget(covariant _CodeBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source || oldWidget.scale != widget.scale || oldWidget.highlight != widget.highlight) {
      _body = null;
      _language = null;
    }
  }
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _body = null;
  }
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = TextStyle(fontFamily: 'monospace', fontSize: 14 * widget.scale, height: 1.45, color: scheme.onSurface);
    return Container(width: double.infinity, margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(color: scheme.surfaceContainerLow, borderRadius: BorderRadius.circular(8), border: Border.all(color: scheme.outlineVariant)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          IconButton(tooltip: collapsed ? 'Развернуть код' : 'Свернуть код',
            style: IconButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.all(4),
              minimumSize: const Size(32, 32),
              tapTargetSize: MaterialTapTargetSize.padded,
            ),
            icon: Icon(collapsed ? Icons.chevron_right : Icons.expand_more), onPressed: () {
              setState(() => collapsed = !collapsed);
              widget.onCollapsedChanged(collapsed);
              widget.onToggle();
              WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) widget.onToggle(); });
            }),
          Expanded(child: Text(_language ??= detectCodeLanguage(widget.source), style: Theme.of(context).textTheme.labelMedium?.copyWith(fontSize: 12 * widget.scale))),
          PopupMenuButton<String>(tooltip: 'Действия с блоком кода', onSelected: (action) async {
            if (action == 'edit') widget.onEdit();
            if (action == 'delete') widget.onDelete();
            if (action == 'copy') {
              await Clipboard.setData(ClipboardData(text: widget.source));
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Код скопирован')));
            }
          }, itemBuilder: (_) => const [
            RoundedPopupMenuItem(value: 'edit', child: Text('Редактировать код')),
            RoundedPopupMenuItem(value: 'copy', child: Text('Копировать код')),
            RoundedPopupMenuItem(value: 'delete', child: Text('Удалить блок кода')),
          ]),
        ]),
        if (!collapsed) _body ??= RepaintBoundary(child: Padding(padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
          child: SingleChildScrollView(scrollDirection: Axis.horizontal,
            child: Text.rich(widget.highlight ? highlightedCode(context, widget.source, style) : TextSpan(text: widget.source, style: style))))),
      ]));
  }
}
