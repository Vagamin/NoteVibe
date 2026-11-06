import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('automatic update check and settings describe five minutes, not six hours', () {
    final home = File('lib/ui/layout/home_screen.dart').readAsStringSync();
    final settings = File('lib/ui/settings/settings_screen.dart').readAsStringSync();
    expect(home, contains('now - last < const Duration(minutes: 5).inMilliseconds'));
    expect(home, isNot(contains('Duration(hours: 6)')));
    expect(settings, contains('Не чаще одного раза в 5 минут.'));
    expect(settings, isNot(contains('6 часов')));
  });
}
