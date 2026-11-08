import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Release notes must survive publishing: the text is written as UTF-8 files and
/// passed with --notes-file. This guards the check that was missing in earlier releases.
void main() {
  test('release note files are valid UTF-8 without replacement characters', () {
    final dir = Directory('release');
    if (!dir.existsSync()) return;
    for (final f in dir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.md'))) {
      final text = f.readAsStringSync();
      expect(text.contains('\uFFFD'), isFalse, reason: '${f.path} has broken characters');
      // Valid Russian words (e.g. «Яндекс») must not be treated as mojibake.
      expect(RegExp(r'Рџ|РЅ|СЃ|СЏ|â€').hasMatch(text), isFalse, reason: '${f.path} looks mis-decoded');
    }
  });
}
