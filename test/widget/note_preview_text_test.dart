import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/domain/note.dart';
import 'package:notevibe/ui/notes_list/note_preview_text.dart';

void main() {
  test('preview keeps inline runs, spaces and block attributes', () {
    final lines = noteLines(jsonEncode([
      {'insert': ' Red ', 'attributes': {'color': '#D32F2F', 'bold': true}},
      {'insert': 'marked', 'attributes': {'background': '#FBC02D', 'italic': true, 'underline': true}},
      {'insert': '\n', 'attributes': {'list': 'checked', 'align': 'right'}},
      {'insert': 'Next\n', 'attributes': {'header': 2}},
    ]), 'fallback');
    expect(lines, hasLength(2));
    expect(lines.first.text, ' Red marked');
    expect(lines.first.kind, 'checked');
    expect(lines.first.runs, hasLength(2));
    expect(lines.first.runs.first.attributes['color'], '#D32F2F');
    expect(lines.first.attributes['align'], 'right');
    expect(lines.last.attributes['header'], 2);
    expect(noteLines('invalid', 'fallback').single.text, 'fallback');
  });

  testWidgets('preview paints colors and combined inline decorations', (tester) async {
    const line = NoteLine('Formatted', 'plain', runs: [NoteRun('Formatted', {
      'color': '#D32F2F', 'background': '#FBC02D', 'bold': true,
      'italic': true, 'underline': true, 'strike': true,
    })]);
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: NotePreviewText(line: line))));
    final text = tester.widget<Text>(find.byType(Text));
    final run = (text.textSpan! as TextSpan).children!.single as TextSpan;
    expect(run.style!.color, const Color(0xFFD32F2F));
    expect(run.style!.backgroundColor, const Color(0xFFFBC02D));
    expect(run.style!.fontWeight, FontWeight.bold);
    expect(run.style!.fontStyle, FontStyle.italic);
    expect(run.style!.decoration!.contains(TextDecoration.underline), isTrue);
    expect(run.style!.decoration!.contains(TextDecoration.lineThrough), isTrue);
    expect(previewColor('not a color'), isNull);
  });
}
