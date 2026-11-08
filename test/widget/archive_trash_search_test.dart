import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/ui/archive/archive_screen.dart';
import 'package:notevibe/ui/trash/trash_screen.dart';
import 'package:notevibe/ui/providers.dart';

import 'app_test.dart' show makeServices;

void main() {
  for (final archived in [true, false]) {
    testWidgets('${archived ? 'archive' : 'trash'} opens search from icon and filters notes', (tester) async {
      late AppServices services;
      await tester.runAsync(() async => services = await makeServices());
      final first = services.store.createNote(title: 'Альфа');
      final second = services.store.createNote(title: 'Бета');
      if (archived) {
        services.store.setArchived([first.id, second.id], true);
      } else {
        services.store.trashNotes([first.id, second.id]);
      }
      await tester.pumpWidget(ProviderScope(overrides: [servicesProvider.overrideWithValue(services)],
        child: MaterialApp(home: archived ? const ArchiveScreen() : const TrashScreen())));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.byTooltip('Поиск'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Альфа');
      await tester.pumpAndSettle();
      expect(find.text('Альфа', skipOffstage: true), findsNWidgets(2));
      expect(find.text('Бета'), findsNothing);
      await tester.tap(find.byTooltip('Закрыть поиск'));
      await tester.pumpAndSettle();
      expect(find.text('Бета'), findsOneWidget);
      await tester.tap(find.byTooltip('Поиск'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  test('preview options include four and five lines', () {
    expect(PreviewLines.four.lines, 4);
    expect(PreviewLines.five.lines, 5);
    expect(PreviewLines.full.lines, -1);
  });
}
