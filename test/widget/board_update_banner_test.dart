import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/main.dart';
import 'package:notevibe/ui/providers.dart';
import 'package:notevibe/ui/widgets/update_banner.dart';
import 'package:notevibe/update/update_service.dart';
import 'app_test.dart' show makeServices;

void main() {
  testWidgets('update banner stays fixed and dismisses without resetting board', (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late AppServices s;
    await tester.runAsync(() async => s = await makeServices());
    s.store.setSetting('updates_auto', 'true');
    final folder = s.store.createFolder('Работа');
    s.store.createNote(title: 'Заметка', folderId: folder.id);
    await tester.pumpWidget(ProviderScope(overrides: [servicesProvider.overrideWithValue(s)], child: const NoteVibeApp()));
    await tester.pumpAndSettle();
    expect(find.byType(UpdateBanner), findsOneWidget);
    final rect = tester.getRect(find.byType(UpdateBanner));
    await tester.drag(find.byType(PageView), const Offset(-350, 0));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byType(UpdateBanner)), rect);
    final container = ProviderScope.containerOf(tester.element(find.byType(NoteVibeApp)));
    expect(container.read(folderSelectionProvider), folder.id);
    await tester.tap(find.text('Позже'));
    await tester.pumpAndSettle();
    expect(find.byType(UpdateBanner), findsNothing);
    expect(container.read(folderSelectionProvider), folder.id);
    expect(tester.takeException(), isNull);
  }, skip: !UpdateService.demo);
}
