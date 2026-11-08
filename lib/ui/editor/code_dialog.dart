import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Conservative hints only: language detection never changes source text.
String detectCodeLanguage(String text) {
  if (RegExp(r'\bfn\s+\w+\s*[(<]|\b(?:println|vec|format)!\s*\(|\b(?:impl|trait)\s+\w+|\blet\s+mut\b').hasMatch(text)) return 'Rust';
  if (RegExp(r'\bfunc\s+(?:\([^)]*\)\s*)?\w+\s*\(|\bfmt\.(?:Print|Sprint)|\bpackage\s+main\b').hasMatch(text)) return 'Go';
  if (RegExp(r'\bfun\s+\w+\s*\(|\b(?:data|sealed)\s+class\b|\bval\s+\w+\s*[:=]').hasMatch(text)) return 'Kotlin';
  if (RegExp(r'\bimport\s+(?:SwiftUI|Foundation|UIKit)\b|\b(?:guard\s+let|func\s+\w+\s*\([^)]*\)\s*->)|\blet\s+\w+\s*:\s*(?:String|Int|Double)\b').hasMatch(text)) return 'Swift';
  if (RegExp(r'<\?php|\$(?:this|\w+)\s*->').hasMatch(text)) return 'PHP';
  if (RegExp(r'(^|\n)\s*(?:require_relative\s|puts\s|class\s+\w+\s*<)|\bdo\s*\|[^|]+\|').hasMatch(text)) return 'Ruby';
  if (RegExp(r'\b(?:Write-Host|Write-Output|Get-ChildItem|Get-Process|Set-Location|param\s*\()|\$env:', caseSensitive: false).hasMatch(text)) return 'PowerShell';
  if (RegExp(r'^#![^\n]*\b(?:bash|sh|zsh)\b|(^|\n)\s*(?:if\s+\[|then\s*$|fi\s*$|export\s+\w+=)|\becho\s+[\x22\x27$]', multiLine: true).hasMatch(text)) return 'Bash/Shell';
  if (RegExp(r'[^{}]+\{\s*(?:--[\w-]+|color|background(?:-color)?|display|margin(?:-\w+)?|padding(?:-\w+)?|font-[\w-]+|width|height)\s*:', multiLine: true).hasMatch(text)) return 'CSS';
  if (RegExp(r'(^|\n)\s*(def |from \w+ import |import \w+\s*\n|print\()').hasMatch(text)) return 'Python';
  if (RegExp(r'\b(SELECT\s+.+\s+FROM|CREATE TABLE|INSERT INTO)\b', caseSensitive: false, dotAll: true).hasMatch(text)) return 'SQL';
  if (RegExp(r'\b(interface |type \w+\s*=)|:\s*(string|number|boolean)\b').hasMatch(text)) return 'TypeScript';
  if (RegExp(r'\b(function |const |let |console\.log|export default)').hasMatch(text)) return 'JavaScript';
  if (RegExp(r'\b(public static void|System\.out\.)').hasMatch(text)) return 'Java';
  if (RegExp(r'\b(Widget|BuildContext|String\?|Future<)|void main\(').hasMatch(text)) return 'Dart';
  if (RegExp(r'\b(using System|namespace |Console\.Write)').hasMatch(text)) return 'C#';
  if (RegExp(r'#include\s*[<"]|std::').hasMatch(text)) return 'C/C++';
  if (RegExp(r'</?[a-zA-Z][^>]*>').hasMatch(text)) return 'HTML/XML';
  return 'Код';
}

class CodeTextController extends TextEditingController {
  bool highlight;
  CodeTextController(String text, {required this.highlight}) : super(text: text);
  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    if (!highlight) return TextSpan(text: text, style: style);
    return highlightedCode(context, text, style);
  }
}

TextSpan highlightedCode(BuildContext context, String text, TextStyle? style) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final pattern = RegExp(r'''(//[^\n]*|\#[^\n]*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\b(?:class|def|return|if|else|for|while|import|from|const|final|var|let|function|void|async|await|true|false|null|None|SELECT|FROM|WHERE)\b|\b\d+(?:\.\d+)?\b)''');
    final spans = <TextSpan>[];
    var offset = 0;
    for (final match in pattern.allMatches(text)) {
      spans.add(TextSpan(text: text.substring(offset, match.start)));
      final token = match.group(0)!;
      final color = token.startsWith('//') || token.startsWith('#') ? Colors.grey
        : token.startsWith('"') || token.startsWith("'") ? (dark ? Colors.lightGreenAccent : Colors.green.shade800)
        : RegExp(r'^\d').hasMatch(token) ? (dark ? Colors.orangeAccent : Colors.brown)
        : (dark ? Colors.lightBlueAccent : Colors.blue.shade800);
      spans.add(TextSpan(text: token, style: TextStyle(color: color)));
      offset = match.end;
    }
    spans.add(TextSpan(text: text.substring(offset)));
    return TextSpan(style: style, children: spans);
}

Future<String?> editCode(BuildContext context, String source, {required bool highlight, double fontScale = 1.0}) async {
  final controller = CodeTextController(source, highlight: highlight);
  final result = await showDialog<String>(context: context, builder: (c) => Dialog(
    insetPadding: const EdgeInsets.all(16),
    backgroundColor: Theme.of(c).cardTheme.color ?? Theme.of(c).colorScheme.surface,
    surfaceTintColor: Colors.transparent,
    clipBehavior: Clip.antiAlias,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    child: SizedBox(width: 850, height: MediaQuery.sizeOf(c).height * .8,
      child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [Expanded(child: Text('Блок кода', style: Theme.of(c).textTheme.titleLarge)),
          IconButton(tooltip: 'Копировать код', icon: const Icon(Icons.copy), onPressed: () async {
            await Clipboard.setData(ClipboardData(text: controller.text));
            if (c.mounted) ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('Код скопирован без изменения отступов')));
          })]),
        const SizedBox(height: 8),
        Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(12),
          child: ColoredBox(color: Theme.of(c).colorScheme.surfaceContainerLow, child: LayoutBuilder(builder: (context, constraints) =>
          SingleChildScrollView(scrollDirection: Axis.horizontal, child: SizedBox(width: constraints.maxWidth < 1000 ? 1000 : constraints.maxWidth,
            child: TextField(controller: controller, expands: true, maxLines: null, minLines: null,
              autocorrect: false, enableSuggestions: false, smartDashesType: SmartDashesType.disabled,
              smartQuotesType: SmartQuotesType.disabled, keyboardType: TextInputType.multiline,
              style: TextStyle(fontFamily: 'monospace', fontSize: 14 * fontScale, height: 1.45, color: Theme.of(c).colorScheme.onSurface),
              decoration: const InputDecoration(filled: false, border: InputBorder.none,
                enabledBorder: InputBorder.none, focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.all(16), hintText: 'Вставьте код…'),
            ))))))),
        const SizedBox(height: 12),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Отмена')),
          const SizedBox(width: 8), FilledButton(onPressed: () => Navigator.pop(c, controller.text), child: const Text('Сохранить')),
        ]),
      ])),
    ),
  ));
  await Future<void>.delayed(const Duration(milliseconds: 300));
  controller.dispose();
  return result;
}
