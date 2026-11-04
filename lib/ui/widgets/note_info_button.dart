import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class NoteInfoButton extends StatelessWidget {
  final DateTime createdAt;
  final DateTime updatedAt;
  const NoteInfoButton({super.key, required this.createdAt, required this.updatedAt});

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Сведения о заметке',
    icon: const Icon(Icons.info_outline),
    onPressed: () => showDialog<void>(
      context: context,
      builder: (context) {
        final format = DateFormat('d MMM yyyy, HH:mm', 'ru');
        return AlertDialog(
          title: const Text('Сведения о заметке'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Дата создания'), Text(format.format(createdAt)),
            const SizedBox(height: 16),
            const Text('Дата изменения'), Text(format.format(updatedAt)),
          ]),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Закрыть'))],
        );
      },
    ),
  );
}
