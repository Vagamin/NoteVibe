import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/ui/editor/note_boundaries.dart';

void main() {
  for (final style in ['full', 'short', 'off']) {
    for (final edges in noteBoundaryEdges.keys) {
      testWidgets('note boundaries: $style / $edges', (tester) async {
        await tester.pumpWidget(MaterialApp(home: SizedBox(width: 400, child: Column(children: [
          NoteBoundary(style: style, edges: edges, start: true),
          NoteBoundary(style: style, edges: edges, start: false),
        ]))));
        final count = style == 'off' || edges == 'off' ? 0 : edges == 'both' ? 2 : 1;
        expect(find.byType(Divider), findsNWidgets(count));
        if (style == 'short') {
          for (var i = 0; i < count; i++) {
            expect(tester.getSize(find.byType(Divider).at(i)).width, 800);
          }
        }
      });
    }
  }
}
