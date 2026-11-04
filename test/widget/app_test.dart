import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:notevibe/data/attachment_storage.dart';
import 'package:notevibe/data/note_store.dart';
import 'package:notevibe/domain/version_vector.dart';
import 'package:notevibe/main.dart';
import 'package:notevibe/sync/crypto/keys.dart';
import 'package:notevibe/sync/crypto/secure_channel.dart';
import 'package:notevibe/sync/sync_service.dart';
import 'package:notevibe/ui/layout/home_screen.dart';
import 'package:notevibe/ui/providers.dart';

Future<AppServices> makeServices() async {
  final store = NoteStore.inMemory(deviceId: 'TEST');
  final ks = MemoryKeyStore();
  final ident = await DeviceIdentity.fromSeed('TEST', 'Test', List.filled(32, 7));
  // Not started: no sockets in widget tests.
  final sync = SyncService(
    store: store,
    peerKeys: PeerKeys(ks),
    identity: ident,
    enableDiscovery: false,
    kdf: CodeKdf.fast,
  );
  return AppServices(store, sync, AttachmentStorage(Directory.systemTemp.createTempSync('nv_att')));
}

Future<void> pumpApp(WidgetTester tester, AppServices s, {Size size = const Size(1280, 800)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [servicesProvider.overrideWithValue(s)],
    child: const NoteVibeApp(),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => initializeDateFormatting('ru'));

  testWidgets('note dates are hidden behind information button', (tester) async {
    late AppServices s;
    await tester.runAsync(() async => s = await makeServices());
    s.store.createNote(title: 'Сведения');
    await pumpApp(tester, s);
    await tester.tap(find.text('Сведения'));
    await tester.pumpAndSettle();
    expect(find.text('Дата создания'), findsNothing);
    await tester.tap(find.byTooltip('Сведения о заметке'));
    await tester.pumpAndSettle();
    expect(find.text('Дата создания'), findsOneWidget);
    expect(find.text('Дата изменения'), findsOneWidget);
    expect(find.byTooltip('Переместить в корзину'), findsOneWidget);
  });

  test('voice preview setting persists independently of text preview', () async {
    final s = await makeServices();
    final container = ProviderContainer(overrides: [servicesProvider.overrideWithValue(s)]);
    expect(container.read(voicePreviewProvider), VoicePreview.all);
    container.read(voicePreviewProvider.notifier).set(VoicePreview.two);
    expect(s.store.getSetting('voice_preview'), 'two');
    expect(container.read(previewLinesProvider), PreviewLines.two);
    container.dispose();
    final restored = ProviderContainer(overrides: [servicesProvider.overrideWithValue(s)]);
    expect(restored.read(voicePreviewProvider), VoicePreview.two);
    restored.dispose();
    await s.sync.stop();
    s.store.dispose();
  });

  testWidgets('desktop: drag a note anywhere on the card in manual order', (tester) async {
    late AppServices s;
    await tester.runAsync(() async {
      s = await makeServices();
      s.store.createNote(title: 'Первая');
      s.store.createNote(title: 'Вторая');
      s.store.createNote(title: 'Третья');
      s.store.setSetting('manual_order', 'true');
    });
    await pumpApp(tester, s);

    final before = s.store.listNotes(manual: true).map((n) => n.title).toList();
    expect(before.first, 'Третья');

    final handle = find.text('Третья');
    final start = tester.getCenter(handle);
    final gesture = await tester.startGesture(start, kind: PointerDeviceKind.mouse);
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.moveBy(const Offset(0, 140));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.up();
    await tester.pumpAndSettle();

    final after = s.store.listNotes(manual: true).map((n) => n.title).toList();
    expect(after, isNot(equals(before)));
    expect(after.toSet(), before.toSet());
  });

  testWidgets('desktop: two panes, Ctrl+N creates note, editor autosaves', (tester) async {
    late AppServices s;
    await tester.runAsync(() async => s = await makeServices());
    await pumpApp(tester, s);

    expect(find.text('Заметок пока нет.\nНажмите «+», чтобы создать первую.'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing); // desktop layout

    await tester.tap(find.textContaining('Новая заметка'));
    await tester.pumpAndSettle();
    expect(s.store.listNotes(), hasLength(1));
    expect(find.byType(QuillEditor), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Заголовок'), 'Покупки');
    await tester.pump(const Duration(milliseconds: 600));
    expect(s.store.listNotes().single.title, 'Покупки');

    final controller = tester.widget<QuillEditor>(find.byType(QuillEditor)).controller;
    controller.replaceText(0, 0, 'молоко', const TextSelection.collapsed(offset: 6));
    await tester.pump(const Duration(milliseconds: 600));
    expect(s.store.listNotes().single.plainText.trim(), 'молоко');
    await tester.pumpAndSettle();
    expect(find.text('Покупки'), findsWidgets); // in list
  });

  testWidgets('Ctrl+B / Ctrl+I / Ctrl+U toggle formatting', (tester) async {
    late AppServices s;
    await tester.runAsync(() async => s = await makeServices());
    final n = s.store.createNote(
        title: 't', content: jsonEncode([{'insert': 'hello world\n'}]), plainText: 'hello world');
    await pumpApp(tester, s);
    await tester.tap(find.text('t'));
    await tester.pumpAndSettle();

    final controller = tester.widget<QuillEditor>(find.byType(QuillEditor)).controller;
    await tester.tap(find.byType(QuillEditor));
    await tester.pumpAndSettle();
    controller.updateSelection(
        const TextSelection(baseOffset: 0, extentOffset: 5), ChangeSource.local);
    await tester.pump();

    for (final key in [LogicalKeyboardKey.keyB, LogicalKeyboardKey.keyI, LogicalKeyboardKey.keyU]) {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
    }
    final attrs = controller.getSelectionStyle().attributes;
    expect(attrs.containsKey(Attribute.bold.key), isTrue);
    expect(attrs.containsKey(Attribute.italic.key), isTrue);
    expect(attrs.containsKey(Attribute.underline.key), isTrue);

    await tester.pump(const Duration(milliseconds: 600));
    final saved = s.store.getNote(n.id)!.content;
    expect(saved, contains('"bold":true'));
    expect(saved, contains('"underline":true'));
  });

  testWidgets('checklist button turns line into checkbox item', (tester) async {
    late AppServices s;
    await tester.runAsync(() async => s = await makeServices());
    final n = s.store.createNote(title: 'todo', content: jsonEncode([{'insert': 'buy\n'}]), plainText: 'buy');
    await pumpApp(tester, s);
    await tester.tap(find.text('todo'));
    await tester.pumpAndSettle();
    final controller = tester.widget<QuillEditor>(find.byType(QuillEditor)).controller;
    controller.updateSelection(const TextSelection.collapsed(offset: 1), ChangeSource.local);
    await tester.tap(find.byTooltip('Чек-лист'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(s.store.getNote(n.id)!.content, contains('"list":"unchecked"'));
  });

  testWidgets('search filters the list', (tester) async {
    late AppServices s;
    await tester.runAsync(() async => s = await makeServices());
    s.store.createNote(title: 'Рецепт борща', plainText: 'свёкла');
    s.store.createNote(title: 'Работа', plainText: 'отчёт');
    await pumpApp(tester, s);
    expect(find.text('Рецепт борща'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Поиск заметок'), 'отчёт');
    await tester.pumpAndSettle();
    expect(find.text('Рецепт борща'), findsNothing);
    expect(find.text('Работа'), findsOneWidget);
  });

  testWidgets('phone layout: FAB opens full-screen editor, delete returns to list', (tester) async {
    late AppServices s;
    await tester.runAsync(() async => s = await makeServices());
    await pumpApp(tester, s, size: const Size(400, 800));
    expect(find.byType(FloatingActionButton), findsNWidgets(2));
    await tester.tap(find.byTooltip('Новая заметка'));
    await tester.pumpAndSettle();
    expect(find.byType(MobileEditorPage), findsOneWidget);
    expect(find.byTooltip('Жирный (Ctrl+B)'), findsOneWidget);

    await tester.tap(find.byTooltip('Переместить в корзину'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'В корзину'));
    await tester.pumpAndSettle();
    expect(find.byType(MobileEditorPage), findsNothing);
    expect(s.store.listNotes(), isEmpty);
    expect(s.store.listTrashed(), hasLength(1));
  });

  testWidgets('conflict badge and resolution screen', (tester) async {
    late AppServices s;
    await tester.runAsync(() async => s = await makeServices());
    final n = s.store.createNote(title: 'Мой вариант');
    s.store.upsertPeer(deviceId: 'P', name: 'Phone', publicKey: List.filled(32, 1));
    final remote = n.copyWith(
      title: 'Вариант с телефона',
      version: VersionVector({'P': 1}),
      lastDevice: 'P',
      updatedAt: n.updatedAt.subtract(const Duration(minutes: 1)),
    );
    s.store.applyRemoteBatch('P', [RemoteNote(remote)], newCursor: 1);
    expect(s.store.conflictCount, 1);

    await pumpApp(tester, s);
    expect(find.text('Конфликт'), findsOneWidget);
    await tester.tap(find.text('Конфликт'));
    await tester.pumpAndSettle();
    expect(find.text('Вариант с телефона'), findsOneWidget);
    await tester.tap(find.text('Сохранить обе'));
    await tester.pumpAndSettle();
    expect(s.store.conflictCount, 0);
    expect(s.store.listNotes(), hasLength(2));
  });

  testWidgets('theme can be switched to dark', (tester) async {
    late AppServices s;
    await tester.runAsync(() async => s = await makeServices());
    await pumpApp(tester, s);
    await tester.tap(find.byTooltip('Настройки'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Оформление'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Тёмная'));
    await tester.pumpAndSettle();
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.dark);
    expect(s.store.getSetting('theme'), 'dark');
  });
}
