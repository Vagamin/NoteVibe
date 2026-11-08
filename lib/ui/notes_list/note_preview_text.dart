import 'package:flutter/material.dart';
import '../../domain/note.dart';
import '../theme/code_style.dart';

Color? previewColor(dynamic value) {
  if (value is! String || !RegExp(r'^#(?:[a-fA-F0-9]{6}|[a-fA-F0-9]{8})$').hasMatch(value)) return null;
  final number = int.parse(value.substring(1), radix: 16);
  return Color(value.length == 7 ? number | 0xFF000000 : number);
}

/// Read-only projection of Quill formatting without an editor per list card.
class NotePreviewText extends StatelessWidget {
  final NoteLine line;
  final TextStyle? style;
  final bool unlimited;
  const NotePreviewText({super.key, required this.line, this.style, this.unlimited = false});

  @override
  Widget build(BuildContext context) {
    final checked = line.kind == 'checked';
    final scheme = Theme.of(context).colorScheme;
    var base = style ?? DefaultTextStyle.of(context).style;
    final header = line.attributes['header'];
    if (header is int && header >= 1 && header <= 6) {
      base = base.copyWith(fontSize: (base.fontSize ?? 14) * [1.8, 1.5, 1.3, 1.2, 1.1, 1.0][header - 1], fontWeight: FontWeight.bold);
    }
    final code = line.attributes['code-block'] != null;
    if (code) base = base.copyWith(fontFamily: 'monospace', color: scheme.onSurface);
    final runs = line.runs.isEmpty ? [NoteRun(line.text, const {})] : line.runs;
    final text = Text.rich(TextSpan(style: base, children: [for (final run in runs)
      TextSpan(text: run.text, style: TextStyle(
        fontWeight: run.attributes['bold'] == true ? FontWeight.bold : null,
        fontStyle: run.attributes['italic'] == true ? FontStyle.italic : null,
        fontFamily: run.attributes['code'] == true ? 'monospace' : (run.attributes['font'] is String ? run.attributes['font'] as String : null),
        color: previewColor(run.attributes['color']) ?? (run.attributes['link'] != null ? scheme.primary : null),
        backgroundColor: previewColor(run.attributes['background']),
        fontSize: switch (run.attributes['size']) {
          'small' => (base.fontSize ?? 14) * 0.75,
          'large' => (base.fontSize ?? 14) * 1.3,
          'huge' => (base.fontSize ?? 14) * 1.65,
          final String size when double.tryParse(size) != null => double.parse(size) * (base.fontSize ?? 14) / 14,
          _ => null,
        },
        decoration: TextDecoration.combine([
          if (run.attributes['underline'] == true || run.attributes['link'] != null) TextDecoration.underline,
          if (run.attributes['strike'] == true || checked) TextDecoration.lineThrough,
        ]),
      )),
    ]), maxLines: unlimited ? null : 1, overflow: unlimited ? TextOverflow.clip : TextOverflow.ellipsis,
      textAlign: switch (line.attributes['align']) {
        'center' => TextAlign.center, 'right' => TextAlign.right, 'justify' => TextAlign.justify, _ => TextAlign.start,
      });
    Widget result = checked ? Opacity(opacity: 0.5, child: text) : text;
    if (code) {
      result = Container(width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: codeDecoration(context), child: result);
    }
    if (line.attributes['blockquote'] == true) {
      result = Container(padding: const EdgeInsets.only(left: 8), decoration: BoxDecoration(
        border: Border(left: BorderSide(color: scheme.outline, width: 3))), child: result);
    }
    final indent = line.attributes['indent'];
    if (indent is int && indent > 0) result = Padding(padding: EdgeInsets.only(left: indent.clamp(0, 8) * 12.0), child: result);
    return result;
  }
}
