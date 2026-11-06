import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../app_version.dart';
import '../data/temporary_cache.dart';

Future<TemporaryCache> temporaryCache() async {
  final tmp = await getTemporaryDirectory();
  return TemporaryCache([
    Directory(p.join(tmp.path, 'updates')),
    Directory(p.join(tmp.path, 'notevibe_play')),
    Directory(p.join(tmp.path, 'notevibe_gallery')),
    Directory(p.join(tmp.path, 'notevibe_clipboard')),
    Directory(p.join(Directory.systemTemp.path, 'notevibe_open')),
  ], installedVersion: appVersion);
}
