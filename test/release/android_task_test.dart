import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android launcher reuses one application task for notification intents', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    final activity = RegExp(r'<activity\b[^>]*android:name="\.MainActivity"[^>]*>', dotAll: true)
        .firstMatch(manifest)!.group(0)!;
    expect(activity, contains('android:launchMode="singleTask"'));
    expect(activity, isNot(contains('android:taskAffinity=""')));
    final source = File('android/app/src/main/kotlin/com/notevibe/notevibe/MainActivity.kt').readAsStringSync();
    expect(source, contains('super.onNewIntent(intent)'));
    expect(source, contains('setIntent(intent)'));
  });
}
