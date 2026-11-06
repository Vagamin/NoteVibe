import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/ui/settings/vault_unlock.dart';

void main() {
  for (final width in [320.0, 412.0, 1280.0]) {
    for (final brightness in Brightness.values) {
      testWidgets('vault unlock fits $width $brightness', (tester) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(MaterialApp(theme: ThemeData(brightness: brightness),
          home: VaultUnlock(args: const [], onUnlocked: (_) {})));
        await tester.pump();
        expect(find.text('Разблокировать NoteVibe'), findsOneWidget);
        expect(tester.takeException(), isNull);
        final field = tester.widget<TextField>(find.byType(TextField));
        expect(field.obscureText, isTrue);
        await tester.tap(find.byTooltip('Показать пароль'));
        await tester.pump();
        expect(tester.widget<TextField>(find.byType(TextField)).obscureText, isFalse);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
