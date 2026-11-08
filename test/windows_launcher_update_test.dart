import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notevibe/update/update_service.dart';
import 'package:path/path.dart' as p;

void main() {
  test('portable update migrates legacy filename and preserves data', () async {
    final dir = await Directory.systemTemp.createTemp('notevibe-launcher-test-');
    addTearDown(() => dir.delete(recursive: true));
    final legacy = await File(p.join(dir.path, 'NoteVibe-1.5.4-portable.exe')).writeAsString('old');
    final data = await Directory(p.join(dir.path, 'NoteVibe-Data')).create();
    final note = await File(p.join(data.path, 'note.db')).writeAsString('notes');
    final download = await File(p.join(dir.path, 'download.exe')).writeAsString('new');
    final result = await UpdateService.replaceWindowsLauncher(download, legacy.path);
    expect(p.basename(result), 'NoteVibe.exe');
    expect(await File(result).readAsString(), 'new');
    expect(await legacy.exists(), false);
    expect(await download.exists(), false);
    expect(await note.readAsString(), 'notes');
  });

  test('later updates keep stable filename', () async {
    final dir = await Directory.systemTemp.createTemp('notevibe-launcher-test-');
    addTearDown(() => dir.delete(recursive: true));
    final launcher = await File(p.join(dir.path, 'NoteVibe.exe')).writeAsString('old');
    final download = await File(p.join(dir.path, 'download.exe')).writeAsString('new');
    expect(await UpdateService.replaceWindowsLauncher(download, launcher.path), launcher.path);
    expect(await launcher.readAsString(), 'new');
    expect(await dir.list().length, 1);
  });
}
