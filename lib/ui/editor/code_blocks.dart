import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';

import 'code_dialog.dart';

const codeEmbedKey = 'notevibe-code';

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
  void flush() {
    if (code.isEmpty) return;
    result.add({'insert': {codeEmbedKey: {'source': code.toString(), 'id': UniqueKey().toString()}}});
    result.add({'insert': '\n'});
    code.clear();
  }
  for (final raw in ops) {
    final op = Map<String, dynamic>.from(raw as Map);
    final text = op['insert'];
    if (text is! String) { flush(); result.addAll(pending); pending = []; result.add(op); continue; }
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
  const CodeBlockBuilder({required this.scale, required this.highlight, required this.onEdit, required this.onDelete, required this.onToggle});
  @override
  String get key => codeEmbedKey;
  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final data = embedContext.node.value.data as Map;
    return _CodeBlock(key: ValueKey(data['id']), source: data['source'] as String,
      scale: scale, highlight: highlight, onEdit: () => onEdit(embedContext), onDelete: () => onDelete(embedContext), onToggle: onToggle);
  }
}

class _CodeBlock extends StatefulWidget {
  final String source;
  final double scale;
  final bool highlight;
  final VoidCallback onEdit, onDelete, onToggle;
  const _CodeBlock({super.key, required this.source, required this.scale, required this.highlight, required this.onEdit, required this.onDelete, required this.onToggle});
  @override
  State<_CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<_CodeBlock> {
  bool collapsed = false;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = TextStyle(fontFamily: 'monospace', fontSize: 14 * widget.scale, height: 1.45, color: scheme.onSurface);
    return Container(width: double.infinity, margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(color: scheme.surfaceContainerLow, borderRadius: BorderRadius.circular(8), border: Border.all(color: scheme.outlineVariant)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          IconButton(tooltip: collapsed ? 'Развернуть код' : 'Свернуть код',
            icon: Icon(collapsed ? Icons.chevron_right : Icons.expand_more), onPressed: () {
              setState(() => collapsed = !collapsed);
              widget.onToggle();
              WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) widget.onToggle(); });
            }),
          Expanded(child: Text(detectCodeLanguage(widget.source), style: Theme.of(context).textTheme.labelMedium?.copyWith(fontSize: 12 * widget.scale))),
          PopupMenuButton<String>(tooltip: 'Действия с блоком кода', onSelected: (action) async {
            if (action == 'edit') widget.onEdit();
            if (action == 'delete') widget.onDelete();
            if (action == 'copy') {
              await Clipboard.setData(ClipboardData(text: widget.source));
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Код скопирован')));
            }
          }, itemBuilder: (_) => const [
            PopupMenuItem(value: 'edit', child: Text('Редактировать код')),
            PopupMenuItem(value: 'copy', child: Text('Копировать код')),
            PopupMenuItem(value: 'delete', child: Text('Удалить блок кода')),
          ]),
        ]),
        if (!collapsed) Padding(padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
          child: SingleChildScrollView(scrollDirection: Axis.horizontal,
            child: Text.rich(widget.highlight ? highlightedCode(context, widget.source, style) : TextSpan(text: widget.source, style: style)))),
      ]));
  }
}
