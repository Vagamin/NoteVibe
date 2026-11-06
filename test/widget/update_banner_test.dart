import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/ui/widgets/update_banner.dart';

void main() {
  for (final width in [320.0, 412.0, 1280.0]) {
    for (final brightness in Brightness.values) {
      testWidgets('update banner fits $width $brightness and stays visible', (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        var opened = false;
        var dismissed = false;
        await tester.pumpWidget(MaterialApp(theme: ThemeData(brightness: brightness), home: Scaffold(
          body: MediaQuery(data: MediaQueryData(size: Size(width, 900), textScaler: TextScaler.linear(1.3)),
            child: UpdateBanner(version: '1.4.0', onOpen: () => opened = true, onLater: () => dismissed = true)))));
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(seconds: 30));
        expect(find.text('Доступно обновление'), findsOneWidget);
        await tester.tap(find.text('Посмотреть обновление'));
        expect(opened, isTrue);
        await tester.tap(find.text('Позже'));
        expect(dismissed, isTrue);
      });
    }
  }
}
