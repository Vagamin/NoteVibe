import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/ui/widgets/reminder_button.dart';

void main() {
  testWidgets('reminder icon reflects scheduled, absent and expired reminders', (tester) async {
    DateTime? scheduled = DateTime.now().add(const Duration(hours: 1));
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(reminderChannel, (call) async {
      if (call.method == 'reminderGet') return scheduled == null ? null : jsonEncode({'at': scheduled.millisecondsSinceEpoch});
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(reminderChannel, null));
    Future<void> show(String id) async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: ReminderButton(noteId: id, title: 'Note'))));
      await tester.pumpAndSettle();
    }
    await show('active');
    expect(find.byIcon(Icons.notifications_active), findsOneWidget);
    final button = tester.widget<IconButton>(find.byType(IconButton));
    expect(button.style!.backgroundColor!.resolve({}), Colors.transparent);
    expect(button.style!.side!.resolve({}), BorderSide.none);
    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();
    final actions = ['Изменить', 'Удалить', 'Назад']
      .map((label) => find.widgetWithText(FilledButton, label)).toList();
    final sizes = actions.map(tester.getSize).toList();
    expect(sizes[1], sizes[0]);
    expect(sizes[2], sizes[0]);
    expect(tester.getTopLeft(actions[1]).dx, tester.getTopLeft(actions[0]).dx);
    expect(tester.getTopLeft(actions[2]).dy, greaterThan(tester.getBottomLeft(actions[1]).dy));
    await tester.tap(find.text('Назад'));
    await tester.pumpAndSettle();
    scheduled = null;
    await show('none');
    expect(find.byIcon(Icons.notification_add_outlined), findsOneWidget);
    scheduled = DateTime.now().subtract(const Duration(minutes: 1));
    await show('expired');
    expect(find.byIcon(Icons.notification_add_outlined), findsOneWidget);
  });
}
