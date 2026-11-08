import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/ui/widgets/rounded_popup_menu_item.dart';

void main() {
  testWidgets('popup item clips its ink and preserves selection', (tester) async {
    String? selected;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PopupMenuButton<String>(
      onSelected: (value) => selected = value,
      itemBuilder: (_) => const [RoundedPopupMenuItem(value: 'open', child: Text('Открыть файл'))],
    ))));
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    final material = find.descendant(of: find.byType(RoundedPopupMenuItem<String>),
      matching: find.byWidgetPredicate((w) => w is Material && w.clipBehavior == Clip.antiAlias &&
        w.borderRadius == BorderRadius.circular(12)));
    expect(material, findsOneWidget);
    await tester.tap(find.text('Открыть файл'));
    await tester.pumpAndSettle();
    expect(selected, 'open');
  });
}
