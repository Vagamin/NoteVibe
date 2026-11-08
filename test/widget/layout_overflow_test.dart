import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:notevibe/data/note_store.dart';
import 'package:notevibe/domain/version_vector.dart';
import 'package:notevibe/main.dart';
import 'package:notevibe/ui/conflicts/conflict_screen.dart';
import 'package:notevibe/ui/devices/devices_screen.dart';
import 'package:notevibe/ui/layout/home_screen.dart';
import 'package:notevibe/ui/providers.dart';
import 'package:notevibe/ui/settings/settings_screen.dart';

import 'app_test.dart' show makeServices;

/// Renders every screen on narrow phones (incl. large system font) in both
/// themes. Any RenderFlex overflow makes the test fail.
void main() {
  setUpAll(() => initializeDateFormatting('ru'));

  testWidgets('update cards have the same width as other settings cards', (tester) async {
    late AppServices s;
    await tester.runAsync(() async => s = await makeServices());
    tester.view.physicalSize = const Size(1266, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [servicesProvider.overrideWithValue(s)],
      child: const NoteVibeApp(),
    ));
    await tester.pumpAndSettle();
    tester.state<NavigatorState>(find.byType(Navigator).first).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
    await tester.pumpAndSettle();
    final autoSync = find.ancestor(of: find.text('Автосинхронизация'), matching: find.byType(Card)).first;
    final autoUpdates = find.ancestor(of: find.text('Проверять обновления'), matching: find.byType(Card)).first;
    final version = find.ancestor(of: find.textContaining('Текущая версия'), matching: find.byType(Card)).first;
    await tester.ensureVisible(autoSync);
    await tester.pumpAndSettle();
    final expected = tester.getRect(autoSync);
    await tester.ensureVisible(autoUpdates);
    await tester.pumpAndSettle();
    for (final card in [autoUpdates, version]) {
      final actual = tester.getRect(card);
      expect(actual.left, expected.left);
      expect(actual.width, expected.width);
    }
  });

  const sizes = [Size(320, 640), Size(360, 740), Size(412, 915)];
  const scales = [1.0, 1.3];

  Future<AppServices> seeded() async {
    final s = await makeServices();
    s.sync.autoSync = false; // longest status label
    final n = s.store.createNote(
      title: 'РћС‡РµРЅСЊ РґР»РёРЅРЅС‹Р№ Р·Р°РіРѕР»РѕРІРѕРє Р·Р°РјРµС‚РєРё, РєРѕС‚РѕСЂС‹Р№ С‚РѕС‡РЅРѕ РЅРµ РїРѕРјРµСЃС‚РёС‚СЃСЏ РІ РѕРґРЅСѓ СЃС‚СЂРѕРєСѓ',
      plainText: 'РўРµРєСЃС‚ Р·Р°РјРµС‚РєРё ' * 20,
    );
    s.store.upsertPeer(
        deviceId: 'P', name: 'РљРѕРјРїСЊСЋС‚РµСЂ СЃ РѕС‡РµРЅСЊ РґР»РёРЅРЅС‹Рј РёРјРµРЅРµРј MegaPC-Workstation', publicKey: List.filled(32, 1));
    s.store.updatePeerSeen('P', address: '192.168.100.200', port: 47801, synced: true);
    s.store.applyRemoteBatch(
      'P',
      [
        RemoteNote(n.copyWith(
          title: 'Р’РµСЂСЃРёСЏ СЃ РґСЂСѓРіРѕРіРѕ СѓСЃС‚СЂРѕР№СЃС‚РІР° СЃ РґР»РёРЅРЅС‹Рј РЅР°Р·РІР°РЅРёРµРј',
          version: VersionVector({'P': 1}),
          lastDevice: 'P',
        )),
      ],
      newCursor: 1,
    );
    return s;
  }

  for (final size in sizes) {
    for (final scale in scales) {
      for (final dark in [false, true]) {
        testWidgets('no overflow ${size.width.toInt()}x${size.height.toInt()} x$scale ${dark ? 'dark' : 'light'}',
            (tester) async {
          late AppServices s;
          await tester.runAsync(() async => s = await seeded());
          s.store.setSetting('theme', dark ? 'dark' : 'light');
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.view.reset);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

          await tester.pumpWidget(ProviderScope(
            overrides: [servicesProvider.overrideWithValue(s)],
            child: const NoteVibeApp(),
          ));
          await tester.pumpAndSettle();

          final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
          final noteId = s.store.listNotes().first.id;
          final screens = <Widget>[
            const DevicesScreen(),
            const JoinPairingScreen(),
            const SettingsScreen(),
            const ConflictScreen(),
            MobileEditorPage(noteId: noteId),
          ];
          for (final screen in screens) {
            nav.push(MaterialPageRoute(builder: (_) => screen));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull, reason: '${screen.runtimeType}');
            _expectSingleLineButtonLabels(tester, '${screen.runtimeType}');
            nav.pop();
            await tester.pumpAndSettle();
          }
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}

/// Button labels must not wrap onto a second line (e.g. "Системна-я").
void _expectSingleLineButtonLabels(WidgetTester tester, String screen) {
  final labels = find.descendant(
    of: find.byWidgetPredicate((w) => w is ButtonStyleButton || w is SegmentedButton),
    matching: find.byType(RichText),
  );
  for (final e in labels.evaluate()) {
    final rp = e.renderObject! as RenderParagraph;
    if (!rp.hasSize || rp.text.toPlainText().trim().isEmpty) continue;
    final lines = rp
        .getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: rp.text.toPlainText().length))
        .map((b) => b.top.round())
        .toSet();
    expect(lines.length, lessThanOrEqualTo(1),
        reason: '$screen: label "${rp.text.toPlainText()}" wraps onto ${lines.length} lines');
  }
}
