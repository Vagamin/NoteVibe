import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/ui/providers.dart';
import 'package:notevibe/ui/settings/backup_card.dart';
import 'app_test.dart' show makeServices;

void main() {
  testWidgets('backup import and export are disabled without password protection', (tester) async {
    late AppServices services;
    await tester.runAsync(() async => services = await makeServices());
    await tester.pumpWidget(ProviderScope(overrides: [servicesProvider.overrideWithValue(services)],
      child: const MaterialApp(home: Scaffold(body: BackupCard()))));
    await tester.pumpAndSettle();
    expect(find.text('Для импорта и экспорта включите защиту данных паролем.'), findsOneWidget);
    final buttons = tester.widgetList<TextButton>(find.byType(TextButton)).toList();
    expect(buttons, hasLength(2));
    expect(buttons.every((button) => button.onPressed == null), isTrue);
    expect(tester.takeException(), isNull);
  });
}
