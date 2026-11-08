import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../domain/note.dart';
import '../editor/code_dialog.dart';

class NoteInfoButton extends StatelessWidget {
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? content;
  const NoteInfoButton({super.key, required this.createdAt, required this.updatedAt, this.content});

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Сведения о заметке',
    icon: const Icon(Icons.info_outline),
    onPressed: () => showDialog<void>(
      context: context,
      builder: (context) {
        final format = DateFormat('d MMM yyyy, HH:mm', 'ru');
        final codeLines = noteLines(content ?? '', '')
          .where((line) => line.attributes['code-block'] != null).toList();
        return AlertDialog(
          title: const Text('Сведения о заметке'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Дата создания'), Text(format.format(createdAt)),
            const SizedBox(height: 16),
            const Text('Дата изменения'), Text(format.format(updatedAt)),
            if (codeLines.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text('Язык программного кода'),
              Text(detectCodeLanguage(codeLines.map((line) => line.text).join('\n'))),
            ],
          ]),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Закрыть'))],
        );
      },
    ),
  );
}
