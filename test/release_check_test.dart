import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/data/note_store.dart';

void main() {
  final src = Platform.environment['NOTEVIBE_RELEASE_DB'];
  test('release check: copy of the working database opens and creates notes', () {
    if (src == null || !File(src).existsSync()) {
      markTestSkipped('set NOTEVIBE_RELEASE_DB to a copy of a real database');
      return;
    }
    final dir = Directory.systemTemp.createTempSync('nv_rc');
    final path = '${dir.path}\\notevibe.db';
    File(src).copySync(path);
    final s = NoteStore.open(path, deviceId: 'PC');
    final before = s.listNotes().length;
    s.createNote(title: 'release check');
    expect(s.listNotes().length, before + 1);
    s.dispose();
    dir.deleteSync(recursive: true);
  });
}
