import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/ui/settings/update_card.dart';
import 'package:notevibe/update/update_service.dart';

void main() {
  testWidgets('known release shows install step without another manual check', (tester) async {
    const release = Release(version: '99.0.0', notes: 'Что нового', pageUrl: 'https://example.com', assets: [
      ReleaseAsset(name: 'NoteVibe.exe', url: 'https://example.com/app', size: 10),
    ]);
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: UpdateCard(initialRelease: release))));
    await tester.pumpAndSettle();
    expect(find.text('Доступна версия 99.0.0'), findsOneWidget);
    expect(find.text('Установить'), findsOneWidget);
    expect(find.text('Проверить обновления'), findsNothing);
  }, skip: !Platform.isWindows);
}
