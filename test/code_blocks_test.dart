import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:notevibe/ui/editor/code_blocks.dart';

void main() {
  test('bulk folding preserves long code, blank lines and formatted text', () {
    final source = '${List.generate(5000, (i) => '\tprint("line $i")  ').join('\n')}\n\n';
    final original = <Map<String, dynamic>>[
      {'insert': 'До\nЕщё строка\n', 'attributes': {'bold': true}},
      {'insert': source, 'attributes': {'code-block': true}},
      {'insert': 'После\n'},
    ];
    final folded = foldCodeBlocks(original);
    expect(folded.where((op) => op['insert'] is Map), hasLength(1));
    final expanded = expandCodeBlocks(folded);
    expect(Document.fromJson(expanded).toPlainText(), Document.fromJson(original).toPlainText());
    expect(expanded.first['attributes'], {'bold': true});
    expect(expanded.where((op) => (op['attributes'] as Map?)?['code-block'] == true), hasLength(5001));
  });

  test('bulk folding handles code and ordinary lines split across operations', () {
    final original = <Map<String, dynamic>>[
      {'insert': 'pri'},
      {'insert': 'nt(1)\n', 'attributes': {'code-block': true}},
      {'insert': '\nprint(2)\n', 'attributes': {'code-block': true}},
      {'insert': 'Обычный ', 'attributes': {'bold': true}},
      {'insert': 'текст\nПродолжение\n'},
    ];
    final expanded = expandCodeBlocks(foldCodeBlocks(original));
    expect(Document.fromJson(expanded).toPlainText(), Document.fromJson(original).toPlainText());
    expect(expanded.where((op) => (op['attributes'] as Map?)?['bold'] == true).single['insert'], 'Обычный ');
    expect(expanded.where((op) => (op['attributes'] as Map?)?['code-block'] == true), hasLength(3));
  });
  test('presentation folding preserves standard code and mixed ordinary lines', () {
    final original = <Map<String, dynamic>>[
      {'insert': 'До\n'},
      {'insert': '\tprint(42)\n\n', 'attributes': {'code-block': true}},
      {'insert': 'Между\n'},
      {'insert': 'fn main() {}\n', 'attributes': {'code-block': true}},
      {'insert': 'После\n'},
    ];
    final folded = foldCodeBlocks(original);
    expect(folded.where((op) => op['insert'] is Map), hasLength(2));
    final expanded = expandCodeBlocks(folded);
    expect(expanded.map((op) => op['insert']).join(), 'До\n\tprint(42)\n\nМежду\nfn main() {}\nПосле\n');
    expect(expanded.where((op) => (op['attributes'] as Map?)?['code-block'] == true), hasLength(3));
  });
}
