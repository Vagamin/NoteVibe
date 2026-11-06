import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/note_backup.dart';
import '../providers.dart';

class BackupCard extends ConsumerStatefulWidget {
  const BackupCard({super.key});
  @override
  ConsumerState<BackupCard> createState() => _BackupCardState();
}

class _BackupCardState extends ConsumerState<BackupCard> {
  bool _busy = false;

  Future<bool> _authorize() async {
    final vault = ref.read(servicesProvider).vault;
    if (vault == null) return true;
    final controller = TextEditingController();
    final password = await showDialog<String>(context: context, builder: (c) => AlertDialog(
      title: const Text('Подтвердите пароль'),
      content: TextField(controller: controller, obscureText: true, autofocus: true,
        autocorrect: false, enableSuggestions: false, decoration: const InputDecoration(labelText: 'Пароль хранилища')),
      actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Отмена')),
        FilledButton(onPressed: () => Navigator.pop(c, controller.text), child: const Text('Продолжить'))],
    ));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    controller.dispose();
    if (password == null) return false;
    await vault.verifyPassword(password);
    return true;
  }

  Future<void> _run(bool importing) async {
    if (_busy) return;
    setState(() => _busy = true);
    final services = ref.read(servicesProvider);
    Uint8List? bytes;
    try {
      if (!await _authorize() || !mounted) return;
      if (importing) {
        final picked = await FilePicker.pickFiles();
        if (picked.isEmpty) return;
        final file = File(picked.first.path!);
        if (await file.length() > NoteBackup.maxBytes) throw const FormatException('Файл больше 512 МБ');
        bytes = await file.readAsBytes();
        if (!mounted) return;
        final replace = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
          title: const Text('Как восстановить заметки?'),
          content: const Text('Добавление создаст независимые копии. Замена удалит все текущие заметки, включая архив и корзину, и восстановит заметки из копии. Изменения передаются сопряжённым устройствам. Настройки и сопряжения сохранятся.\n\nПеред импортом выберите место для страховочного ZIP без шифрования. Если отменить сохранение, импорт не начнётся. В файле .db нет самих вложений.'),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Отмена')),
            OutlinedButton(onPressed: () => Navigator.pop(c, true), child: const Text('Заменить все заметки')),
            FilledButton(onPressed: () => Navigator.pop(c, false), child: const Text('Добавить к существующим'))],
        ));
        if (replace == null) return;
        await services.flush();
        final safety = await NoteBackup.export(services.store, services.attachments);
        try {
          final saved = await FilePicker.saveFile(fileName: 'NoteVibe-before-import-${DateTime.now().millisecondsSinceEpoch}.zip',
            bytes: safety, mimeType: 'application/zip', dialogTitle: 'Сохранить страховочную копию без шифрования');
          if (saved == null) return;
        } finally { safety.fillRange(0, safety.length, 0); }
        await services.sync.stop();
        try {
          final count = await NoteBackup.restore(bytes, services.store, services.attachments, replace: replace);
          await services.flush();
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Восстановлено заметок: $count')));
        } finally { if (!services.mobileLocked) await services.sync.start(); }
      } else {
        await services.flush();
        bytes = await NoteBackup.export(services.store, services.attachments);
        await FilePicker.saveFile(fileName: 'NoteVibe-${DateTime.now().millisecondsSinceEpoch}.zip',
          bytes: bytes, mimeType: 'application/zip', dialogTitle: 'Сохранить полный бэкап');
      }
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Операция не завершена: $error')));
    } finally {
      bytes?.fillRange(0, bytes.length, 0);
      if (Platform.isAndroid) {
        try { await FilePicker.clearTemporaryFiles(); } catch (_) { /* Best-effort plugin cache cleanup. */ }
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Card(child: Padding(padding: const EdgeInsets.all(16),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.backup_outlined),
        title: const Text('Резервные копии'), subtitle: const Text('ZIP: база и доступные на устройстве вложения.')),
      const Text('Архив не зашифрован. Храните его в безопасном месте. Отсутствующие на устройстве файлы в копию не входят. Импорт поддерживает ZIP NoteVibe и прежние файлы .db.'),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 4, children: [
        TextButton.icon(onPressed: _busy ? null : () => _run(false), icon: const Icon(Icons.save_alt), label: const Text('Сохранить ZIP', maxLines: 1, overflow: TextOverflow.ellipsis)),
        TextButton.icon(onPressed: _busy ? null : () => _run(true), icon: const Icon(Icons.restore), label: const Text('Импортировать', maxLines: 1, overflow: TextOverflow.ellipsis)),
      ]),
      if (_busy) const LinearProgressIndicator(),
    ])));
}
