import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/ui/widgets/overflow_title_hint.dart';

void main() {
  testWidgets('full title hint appears on hold only for truncated titles', (tester) async {
    const title = 'Очень длинный заголовок заметки, который не помещается';
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox(width: 120,
      child: OverflowTitleHint(title: title, style: TextStyle(fontSize: 16),
        child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis))))));
    expect(find.byType(Tooltip), findsOneWidget);
    await tester.longPress(find.byType(OverflowTitleHint));
    await tester.pumpAndSettle();
    expect(find.text(title), findsNWidgets(2));
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox(width: 300,
      child: OverflowTitleHint(title: 'Короткий', style: TextStyle(fontSize: 16), child: Text('Короткий'))))));
    await tester.pumpAndSettle();
    expect(find.byType(Tooltip), findsNothing);
  });
}
