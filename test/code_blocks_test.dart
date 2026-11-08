import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/ui/editor/code_blocks.dart';

void main() {
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
