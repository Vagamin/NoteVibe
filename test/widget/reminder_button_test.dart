import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/ui/widgets/reminder_button.dart';

void main() {
  testWidgets('reminder back stays on the left and time entry uses digits', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      reminderChannel, (MethodCall call) async => switch (call.method) {
        'reminderGet' => null,
        'reminderPermission' || 'reminderExactAllowed' => true,
        _ => null,
      });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(reminderChannel, null));
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: ReminderButton(noteId: 'test', title: 'Note'))));
    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Назад')).dx, lessThan(tester.getTopLeft(find.text('Выбрать время')).dx));
    await tester.tap(find.text('Выбрать время'));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    final dialog = tester.widget<TimePickerDialog>(find.byType(TimePickerDialog));
    expect(dialog.initialEntryMode, TimePickerEntryMode.input);
    expect(find.byType(TextField), findsNWidgets(2));
  });
}
