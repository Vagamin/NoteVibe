import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

const reminderChannel = MethodChannel('notevibe/update');

class ReminderButton extends StatefulWidget {
  final String noteId;
  final String title;
  final bool compact;
  const ReminderButton({super.key, required this.noteId, required this.title, this.compact = false});
  @override
  State<ReminderButton> createState() => _ReminderButtonState();
}

class _ReminderButtonState extends State<ReminderButton> with WidgetsBindingObserver {
  DateTime? _scheduled;
  String get noteId => widget.noteId;
  String get title => widget.title;
  @override
  void initState() { super.initState(); WidgetsBinding.instance.addObserver(this); _refresh(); }
  @override
  void didUpdateWidget(ReminderButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.noteId != noteId) { _scheduled = null; _refresh(); }
  }
  @override
  void dispose() { WidgetsBinding.instance.removeObserver(this); super.dispose(); }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }
  Future<void> _refresh() async {
    final id = noteId;
    try {
      final raw = await reminderChannel.invokeMethod<String>('reminderGet', {'id': id});
      final at = raw == null ? null : DateTime.fromMillisecondsSinceEpoch((jsonDecode(raw) as Map)['at'] as int);
      if (mounted && id == noteId) setState(() => _scheduled = at);
    } catch (_) { /* Unsupported platforms keep the default icon. */ }
  }

  Future<void> _edit(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final raw = await reminderChannel.invokeMethod<String>('reminderGet', {'id': noteId});
      final existing = raw == null ? null : DateTime.fromMillisecondsSinceEpoch((jsonDecode(raw) as Map)['at'] as int);
      if (!context.mounted) return;
      final action = await showDialog<String>(context: context, builder: (c) => AlertDialog(
        title: const Text('Напомнить прочитать'),
        content: Text(existing == null ? 'Однократное уведомление на этом телефоне.' : 'Назначено: ${DateFormat('dd.MM.yyyy HH:mm').format(existing)}'),
        actions: [SizedBox(width: double.infinity, child: Column(
          mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: () => Navigator.pop(c, 'set'), child: Text(existing == null ? 'Выбрать время' : 'Изменить')),
            if (existing != null) ...[
              const SizedBox(height: 8),
              FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                onPressed: () => Navigator.pop(c, 'cancel'), child: const Text('Удалить')),
            ],
            const SizedBox(height: 8),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: () => Navigator.pop(c), child: const Text('Назад')),
          ],
        ))],
      ));
      if (action == null) return;
      if (action == 'cancel') {
        await reminderChannel.invokeMethod<void>('reminderCancel', {'id': noteId});
        messenger.showSnackBar(const SnackBar(content: Text('Напоминание удалено')));
        return;
      }
      if (!context.mounted) return;
      final allowed = await reminderChannel.invokeMethod<bool>('reminderPermission') ?? false;
      if (!allowed) {
        messenger.showSnackBar(const SnackBar(content: Text('Разрешите уведомления NoteVibe в настройках Android')));
        return;
      }
      if (!(await reminderChannel.invokeMethod<bool>('reminderExactAllowed') ?? false)) {
        if (!context.mounted) return;
        final open = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
          title: const Text('Точные напоминания'),
          content: const Text('Разрешите будильники и напоминания в системных настройках, затем вернитесь и выберите время.'),
          actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Позже')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Настройки'))],
        ));
        if (open == true) await reminderChannel.invokeMethod<void>('reminderExactSettings');
        return;
      }
      if (!context.mounted) return;
      final now = DateTime.now();
      final initial = existing != null && existing.isAfter(now) ? existing : now.add(const Duration(hours: 1));
      final day = await showDatePicker(context: context, initialDate: initial, firstDate: DateUtils.dateOnly(now), lastDate: now.add(const Duration(days: 3650)));
      if (day == null || !context.mounted) return;
      final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(initial),
        initialEntryMode: TimePickerEntryMode.input,
        builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true), child: child!));
      if (time == null) return;
      final at = DateTime(day.year, day.month, day.day, time.hour, time.minute);
      if (!at.isAfter(DateTime.now())) {
        messenger.showSnackBar(const SnackBar(content: Text('Выберите время в будущем')));
        return;
      }
      await reminderChannel.invokeMethod<void>('reminderSchedule', {'id': noteId, 'title': title.trim().isEmpty ? 'Заметка' : title, 'at': at.millisecondsSinceEpoch});
      messenger.showSnackBar(SnackBar(content: Text('Напоминание: ${DateFormat('dd.MM.yyyy HH:mm').format(at)}')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Не удалось настроить напоминание: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = _scheduled?.isAfter(DateTime.now()) ?? false;
    return IconButton(
      padding: widget.compact ? EdgeInsets.zero : null,
      constraints: widget.compact ? const BoxConstraints(minWidth: 36, minHeight: 48) : null,
      tooltip: active ? 'Напоминание: ${DateFormat('dd.MM.yyyy HH:mm').format(_scheduled!)}' : 'Напомнить прочитать',
      style: IconButton.styleFrom(
        tapTargetSize: widget.compact ? MaterialTapTargetSize.shrinkWrap : null,
        side: BorderSide.none,
        backgroundColor: Colors.transparent,
        foregroundColor: active ? Theme.of(context).colorScheme.primary : null),
      icon: Icon(active ? Icons.notifications_active : Icons.notification_add_outlined),
      onPressed: () async { await _edit(context); await _refresh(); },
    );
  }
}
