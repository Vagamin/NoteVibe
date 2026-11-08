import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/ui/editor/code_dialog.dart';

void main() {
  testWidgets('code editor scales text while preserving monospace and source', (tester) async {
    const source = '\tprint(42)\n';
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => Scaffold(
      body: TextButton(onPressed: () => editCode(context, source, highlight: true, fontScale: 1.85), child: const Text('Open')),
    ))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.style!.fontSize, closeTo(14 * 1.85, 0.01));
    expect(field.style!.fontFamily, 'monospace');
    expect(field.controller!.text, source);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
  });
  testWidgets('code dialog follows dark theme and clips editor corners', (tester) async {
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: Builder(builder: (context) => Scaffold(
      body: TextButton(onPressed: () => editCode(context, '', highlight: true), child: const Text('Open')),
    ))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final dialog = tester.widget<Dialog>(find.byType(Dialog));
    expect(dialog.clipBehavior, Clip.antiAlias);
    expect(Theme.of(tester.element(find.byType(TextField))).brightness, Brightness.dark);
    expect(tester.widget<TextField>(find.byType(TextField)).decoration!.filled, false);
    expect(find.byType(ClipRRect), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
  });
  testWidgets('code editor preserves tabs, spaces and newlines verbatim', (tester) async {
    const code = 'def main():\n\tprint("hello")\n    return 42\n';
    String? saved;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => Scaffold(
      body: TextButton(onPressed: () async { saved = await editCode(context, code, highlight: true); }, child: const Text('Open')),
    ))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, code);
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(saved, code);
    expect(tester.takeException(), isNull);
  });
}
