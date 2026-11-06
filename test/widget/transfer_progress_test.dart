import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/sync/transfer/note_transfer.dart';
import 'package:notevibe/ui/transfer/transfer_screen.dart';

void main() {
  testWidgets('transfer shows real byte progress and separate finalization', (tester) async {
    Future<void> show(NoteTransferProgress progress) => tester.pumpWidget(MaterialApp(home: Scaffold(
      body: TransferProgressCard(progress: progress, status: 'Waiting'))));
    await show(const NoteTransferProgress(1048576, 2097152));
    expect(find.text('50% · 1.00 / 2.00 МБ'), findsOneWidget);
    expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, 0.5);
    await show(const NoteTransferProgress(2097152, 2097152, finalizing: true));
    expect(find.text('Проверка и сохранение заметок…'), findsOneWidget);
    expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, isNull);
    expect(find.textContaining('100%'), findsNothing);
    await show(const NoteTransferProgress(0, 0));
    expect(find.text('Передача текста и подтверждение приёма'), findsOneWidget);
  });
}
