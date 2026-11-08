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
import 'package:notevibe/ui/editor/format_glyph.dart';
import 'package:notevibe/ui/notes_list/notes_list.dart';

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
  testWidgets('code information and conditional toolbar deletion preserve ordinary text', (tester) async {
    late AppServices s;
    await tester.runAsync(() async => s = await makeServices());
    final note = s.store.createNote(title: 'Удаление кода', content: jsonEncode([
      {'insert': 'Обычный текст\n'},
      {'insert': 'print(42)'}, {'insert': '\n', 'attributes': {'code-block': true}},
    ]), plainText: 'Обычный текст\nprint(42)\n');
    await pumpApp(tester, s);
    await tester.tap(find.text('Удаление кода'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Сведения о заметке'));
    await tester.pumpAndSettle();
    expect(find.text('Язык программного кода'), findsOneWidget);
    expect(find.text('Python'), findsOneWidget);
    await tester.tap(find.text('Закрыть'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('Удалить весь код'));
    await tester.tap(find.byTooltip('Удалить весь код'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Удалить'));
    await tester.pumpAndSettle();
    expect(s.store.getNote(note.id)!.plainText, 'Обычный текст\n');
    expect(s.store.getNote(note.id)!.content, isNot(contains('code-block')));
    expect(find.byTooltip('Удалить весь код'), findsNothing);
    await tester.tap(find.byTooltip('Сведения о заметке'));
    await tester.pumpAndSettle();
    expect(find.text('Язык программного кода'), findsNothing);
  });
  testWidgets('desktop can create another note while its only note is open', (tester) async {
    late AppServices s;
    await tester.runAsync(() async => s = await makeServices());
    s.store.createNote(title: 'Единственная');
    await pumpApp(tester, s);
    await tester.tap(find.text('Единственная'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Новая заметка'));
    await tester.pumpAndSettle();
    expect(s.store.listNotes(), hasLength(2));
    expect(find.byTooltip('Новая голосовая заметка'), findsOneWidget);
    final create = find.widgetWithText(FilledButton, 'Новая заметка');
    final voice = find.descendant(of: find.byTooltip('Новая голосовая заметка'), matching: find.byType(FilledButton));
    expect(tester.getSize(create).height, 40);
    expect(tester.getSize(voice).height, tester.getSize(create).height);
  });

  testWidgets('saved code block uses dark theme instead of default white decoration', (tester) async {
    late AppServices s;
    await tester.runAsync(() async => s = await makeServices());
    s.store.setSetting('theme', 'dark');
    s.store.createNote(title: 'Код', content: jsonEncode([
      {'insert': 'print(42)'}, {'insert': '\n', 'attributes': {'code-block': true}},
    ]), plainText: 'print(42)\n');
    await pumpApp(tester, s);
    await tester.tap(find.text('Код'));
    await tester.pumpAndSettle();
    final editor = tester.widget<QuillEditor>(find.byType(QuillEditor));
    final decoration = editor.config.customStyles!.code!.decoration as BoxDecoration;
    expect(decoration.color!.computeLuminance(), lessThan(.3));
  });
  testWidgets('limited preview marks hidden continuation but full preview does not', (tester) async {
    late AppServices s;
    await tester.runAsync(() async => s = await makeServices());
    final note = s.store.createNote(title: 'Test', content: jsonEncode([{'insert': '1\n2\n3\n4\n'}]), plainText: '1\n2\n3\n4\n');
    Future<void> show(PreviewLines preview) async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: NoteCard(note: note, onTap: () {}, previewLines: preview))));
      await tester.pumpAndSettle();
    }
    await show(PreviewLines.three);
    expect(find.byTooltip('В заметке есть продолжение'), findsOneWidget);
    await show(PreviewLines.full);
    expect(find.byTooltip('В заметке есть продолжение'), findsNothing);
    await show(PreviewLines.five);
    expect(find.byTooltip('В заметке есть продолжение'), findsNothing);
  });

  testWidgets('system back cancels bulk selection before leaving home', (tester) async {
    late AppServices s;
    await tester.runAsync(() async => s = await makeServices());
    await pumpApp(tester, s, size: const Size(412, 915));
    final container = ProviderScope.containerOf(tester.element(find.byType(HomeScreen)));
    container.read(selectionProvider.notifier).start();
    container.read(transferSelectionProvider.notifier).set(true);
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(container.read(selectionProvider), isNull);
    expect(container.read(transferSelectionProvider), false);
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets('hidden vault warning does not add a second status-bar inset', (tester) async {
    late AppServices s;
    await tester.runAsync(() async => s = await makeServices());
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = FakeViewPadding(top: 32);
    tester.view.viewPadding = FakeViewPadding(top: 32);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(overrides: [servicesProvider.overrideWithValue(s)], child: const NoteVibeApp()));
    await tester.pumpAndSettle();
    final appBar = find.byType(AppBar).first;
    expect(tester.getTopLeft(appBar).dy, 0);
    expect(tester.getSize(appBar).height, 88);
  });

  testWidgets('code notice follows note font size setting', (tester) async {
    late AppServices s;
    await tester.runAsync(() async => s = await makeServices());
    s.store.setSetting('note_font_size', 'maximum');
    s.store.createNote(title: 'Код', content: jsonEncode([
      {'insert': 'print(42)'}, {'insert': '\n', 'attributes': {'code-block': true}},
    ]), plainText: 'print(42)\n');
    await pumpApp(tester, s);
    final notice = tester.widget<Text>(find.text('Есть программный код'));
    final context = tester.element(find.text('Есть программный код'));
    expect(notice.style!.fontSize, closeTo(Theme.of(context).textTheme.labelSmall!.fontSize! * 1.85, 0.01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('font setting scales editor paragraphs, lists and headings', (tester) async {
    late AppServices s;
    await tester.runAsync(() async => s = await makeServices());
    s.store.setSetting('note_font_size', 'maximum');
    s.store.createNote(title: 'Размер', content: jsonEncode([
      {'insert': 'Обычный\n'},
      {'insert': 'Список'}, {'insert': '\n', 'attributes': {'list': 'unchecked'}},
    ]), plainText: 'Обычный\nСписок\n');
    await pumpApp(tester, s);
    await tester.tap(find.text('Размер'));
    await tester.pumpAndSettle();
    final styles = tester.widget<QuillEditor>(find.byType(QuillEditor)).config.customStyles!;
    expect(styles.paragraph!.style.fontSize, closeTo(17 * 1.85, 0.01));
    expect(styles.lists!.style.fontSize, closeTo(17 * 1.85, 0.01));
    expect(styles.h1!.style.fontSize, greaterThan(styles.paragraph!.style.fontSize!));
    expect(NoteFontSize.values.length, greaterThan(4));
  });

  testWidgets('color controls show current selection colors', (tester) async {
    late AppServices s;
    await tester.runAsync(() async => s = await makeServices());
    s.store.createNote(title: 'Цвета', content: jsonEncode([
      {'insert': 'Цветной', 'attributes': {'color': '#D32F2F', 'background': '#FBC02D'}},
      {'insert': '\n'},
    ]), plainText: 'Цветной\n');
    await pumpApp(tester, s);
    await tester.tap(find.text('Цвета'));
    await tester.pumpAndSettle();
    final controller = tester.widget<QuillEditor>(find.byType(QuillEditor)).controller;
    controller.updateSelection(const TextSelection(baseOffset: 0, extentOffset: 3), ChangeSource.local);
    await tester.pumpAndSettle();
    final color = tester.widget<IconButton>(find.byWidgetPredicate((widget) => widget is IconButton && widget.tooltip == 'Цвет текста'));
    final highlight = tester.widget<IconButton>(find.byWidgetPredicate((widget) => widget is IconButton && widget.tooltip == 'Цвет выделения'));
    expect(color.style!.foregroundColor!.resolve({}), const Color(0xFFD32F2F));
    expect(highlight.style!.foregroundColor!.resolve({}), const Color(0xFFFBC02D));
  });

  testWidgets('new checked-list item starts unchecked', (tester) async {
    late AppServices s;
    await tester.runAsync(() async => s = await makeServices());
    s.store.createNote(title: 'Чек-лист', content: jsonEncode([
      {'insert': 'Готово'},
      {'insert': '\n', 'attributes': {'list': 'checked'}},
    ]), plainText: 'Готово\n');
    await pumpApp(tester, s);
    await tester.tap(find.text('Чек-лист'));
    await tester.pumpAndSettle();
    final controller = tester.widget<QuillEditor>(find.byType(QuillEditor)).controller;
    controller.replaceText(6, 0, '\n', const TextSelection.collapsed(offset: 7));
    await tester.pump();
    expect(controller.getSelectionStyle().attributes[Attribute.list.key]?.value, isNot('checked'));
    expect(find.byTooltip('Цвет текста'), findsOneWidget);
    expect(find.byTooltip('Цвет выделения'), findsOneWidget);
    expect(find.byType(FormatGlyph), findsNWidgets(9));
    for (final element in find.byType(FormatGlyph).evaluate()) {
      expect(tester.getSize(find.byWidget(element.widget)), const Size(24, 24));
    }
    await tester.pump(const Duration(milliseconds: 600));
  });

  testWidgets('toggling first checkbox leaves the last item and editor instance unchanged', (tester) async {
    late AppServices s;
    await tester.runAsync(() async => s = await makeServices());
    s.store.createNote(title: 'Список без мигания', content: jsonEncode([
      for (final text in ['Первый', 'Средний', 'Последний']) ...[
        {'insert': text}, {'insert': '\n', 'attributes': {'list': 'unchecked'}},
      ],
    ]), plainText: 'Первый\nСредний\nПоследний\n');
    await pumpApp(tester, s);
    await tester.tap(find.text('Список без мигания'));
    await tester.pumpAndSettle();
    final controller = tester.widget<QuillEditor>(find.byType(QuillEditor)).controller;
    final boxes = find.descendant(of: find.byType(QuillEditor), matching: find.byIcon(Icons.check_box_outline_blank));
    expect(boxes, findsNWidgets(3));
    await tester.tap(boxes.first);
    await tester.pump();
    expect(find.descendant(of: find.byType(QuillEditor), matching: find.byIcon(Icons.check_box)), findsOneWidget);
    expect(boxes, findsNWidgets(2));
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.widget<QuillEditor>(find.byType(QuillEditor)).controller, same(controller));
    final delta = controller.document.toDelta().toJson();
    expect((delta.last['attributes'] as Map)['list'], 'unchecked');
  });

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

    await tester.tap(find.text('Новая заметка'));
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

  testWidgets('uniform toolbar scrolls and custom history buttons work', (tester) async {
    late AppServices s;
    await tester.runAsync(() async => s = await makeServices());
    s.store.createNote(title: 'Панель', content: jsonEncode([{'insert': 'Текст\n'}]), plainText: 'Текст');
    await pumpApp(tester, s, size: const Size(320, 800));
    await tester.tap(find.text('Панель'));
    await tester.pumpAndSettle();
    final controller = tester.widget<QuillEditor>(find.byType(QuillEditor)).controller;
    controller.updateSelection(const TextSelection(baseOffset: 0, extentOffset: 5), ChangeSource.local);
    await tester.tap(find.byTooltip('Жирный (Ctrl+B)'));
    await tester.pump();
    expect(controller.document.toDelta().toJson().toString(), contains('bold: true'));
    final scroll = find.ancestor(of: find.byTooltip('Повторить'), matching: find.byType(SingleChildScrollView)).first;
    await tester.drag(scroll, const Offset(-500, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Отменить'));
    await tester.pump();
    expect(controller.document.toDelta().toJson().toString(), isNot(contains('bold: true')));
    await tester.tap(find.byTooltip('Повторить'));
    await tester.pump();
    expect(controller.document.toDelta().toJson().toString(), contains('bold: true'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
  });

  testWidgets('search filters the list', (tester) async {
    late AppServices s;
    await tester.runAsync(() async => s = await makeServices());
    s.store.createNote(title: 'Рецепт борща', plainText: 'свёкла');
    s.store.createNote(title: 'Работа', plainText: 'отчёт');
    await pumpApp(tester, s);
    expect(find.text('Рецепт борща'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Поиск заметок'), findsNothing);
    await tester.tap(find.byTooltip('Поиск заметок'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Поиск заметок'), 'отчёт');
    await tester.pumpAndSettle();
    expect(find.text('Рецепт борща'), findsNothing);
    expect(find.text('Работа'), findsOneWidget);
  });

  testWidgets('send selects notes in the home list without destructive actions', (tester) async {
    late AppServices s;
    await tester.runAsync(() async => s = await makeServices());
    s.store.createNote(title: 'Передаваемая заметка');
    await pumpApp(tester, s, size: const Size(400, 800));
    await tester.tap(find.byTooltip('Разовая передача'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    final sendButton = find.widgetWithText(FilledButton, 'Отправить');
    final receiveButton = find.widgetWithText(FilledButton, 'Получить');
    expect(tester.getSize(sendButton).width, tester.getSize(receiveButton).width);
    expect(tester.getCenter(sendButton).dx, tester.getCenter(receiveButton).dx);
    await tester.tap(find.widgetWithText(FilledButton, 'Отправить'));
    await tester.pumpAndSettle();
    expect(find.text('Отправить: 0'), findsOneWidget);
    expect(find.text('Разовая передача'), findsNothing);
    await tester.tap(find.text('Передаваемая заметка'));
    await tester.pumpAndSettle();
    expect(find.text('Отправить: 1'), findsOneWidget);
    expect(find.byTooltip('Отправить выбранные'), findsOneWidget);
    expect(find.byTooltip('Переместить выбранные в корзину'), findsNothing);
    expect(find.byTooltip('В архив'), findsNothing);
    await tester.tap(find.byTooltip('Отменить выбор'));
    await tester.pumpAndSettle();
    expect(find.text('NoteVibe'), findsOneWidget);
    expect(s.store.listNotes(), hasLength(1));
  });

  testWidgets('phone layout: FAB opens full-screen editor, delete returns to list', (tester) async {
    late AppServices s;
    await tester.runAsync(() async => s = await makeServices());
    await pumpApp(tester, s, size: const Size(400, 800));
    expect(find.byType(FloatingActionButton), findsNWidgets(3));
    expect(tester.getSize(find.byTooltip('Разовая передача')), tester.getSize(find.byTooltip('Новая заметка')));
    expect(tester.getCenter(find.byTooltip('Разовая передача')).dx, closeTo(tester.getCenter(find.byTooltip('Новая заметка')).dx, 0.01));
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
