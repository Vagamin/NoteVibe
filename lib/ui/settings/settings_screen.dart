import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';

import '../../app_version.dart';
import '../../sync/sync_service.dart';
import '../../update/update_service.dart';
import '../attachments/attachment_service.dart';
import '../providers.dart';
import '../voice/voice_panel.dart';
import 'update_card.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});
  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late final TextEditingController _name;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: ref.read(syncProvider).identity.name);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _saveName() {
    final n = _name.text.trim();
    if (n.isEmpty) return;
    ref.read(storeProvider).setSetting('device_name', n);
    ref.read(syncProvider).rename(n);
  }

  Future<void> _pickSaveDir() async {
    final dir = await FilePicker.getDirectoryPath(dialogTitle: 'Папка для файлов');
    if (dir == null) return;
    ref.read(storeProvider).setSetting(AttachmentService.saveDirSetting, dir);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(themeModeProvider);
    final sync = ref.watch(syncProvider);
    final status = ref.watch(syncStatusProvider).value ?? sync.currentStatus;
    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Тема', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          LayoutBuilder(builder: (context, c) {
            // Icons only when there is room; labels never wrap mid-word.
            final withIcons = c.maxWidth >= 400 * MediaQuery.textScalerOf(context).scale(1);
            ButtonSegment<ThemeMode> seg(ThemeMode m, String label, IconData icon) => ButtonSegment(
                  value: m,
                  icon: withIcons ? Icon(icon) : null,
                  label: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(label, maxLines: 1, softWrap: false),
                  ),
                );
            return SizedBox(
              width: double.infinity,
              child: SegmentedButton<ThemeMode>(
                showSelectedIcon: false,
                segments: [
                  seg(ThemeMode.system, 'Системная', Icons.brightness_auto),
                  seg(ThemeMode.light, 'Светлая', Icons.light_mode),
                  seg(ThemeMode.dark, 'Тёмная', Icons.dark_mode),
                ],
                selected: {mode},
                onSelectionChanged: (s) => ref.read(themeModeProvider.notifier).set(s.first),
              ),
            );
          }),
          const SizedBox(height: 24),
          Text('Список заметок', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          ListTile(
            leading: const Icon(Icons.view_headline_outlined),
            title: const Text('Сколько показывать в списке'),
            subtitle: Text(ref.watch(previewLinesProvider).label),
            onTap: () async {
              final picked = await showDialog<PreviewLines>(
                context: context,
                builder: (c) => SimpleDialog(
                  title: const Text('Сколько показывать в списке'),
                  children: [
                    for (final p in PreviewLines.values)
                      SimpleDialogOption(
                        onPressed: () => Navigator.pop(c, p),
                        child: Text(p.label),
                      ),
                  ],
                ),
              );
              if (picked != null) ref.read(previewLinesProvider.notifier).set(picked);
            },
          ),
          ListTile(
            leading: const Icon(Icons.format_size),
            title: const Text('Размер шрифта заметок'),
            subtitle: Text('${ref.watch(noteFontSizeProvider).label} · Заголовки и текст в списке и редакторе'),
            onTap: () async {
              final picked = await showDialog<NoteFontSize>(
                context: context,
                builder: (c) => SimpleDialog(
                  title: const Text('Размер шрифта заметок'),
                  children: [
                    for (final f in NoteFontSize.values)
                      SimpleDialogOption(
                        onPressed: () => Navigator.pop(c, f),
                        child: Text(f.label),
                      ),
                  ],
                ),
              );
              if (picked != null) ref.read(noteFontSizeProvider.notifier).set(picked);
            },
          ),
          SwitchListTile(
            secondary: const Icon(Icons.drag_indicator),
            title: const Text('Порядок вручную'),
            subtitle: const Text('Заметки перетаскиваются долгим нажатием. Важные остаются сверху'),
            value: ref.watch(manualOrderProvider),
            onChanged: (v) => ref.read(manualOrderProvider.notifier).set(v),
          ),
          if (Platform.isWindows)
            ListTile(
              leading: const Icon(Icons.mic_none),
              title: const Text('Микрофон для голосовых заметок'),
              subtitle: Text(ref.watch(captureDeviceProvider).isEmpty
                  ? 'По умолчанию'
                  : ref.watch(captureDeviceNameProvider)),
              onTap: () async {
                final devices = await ref.read(voiceServiceProvider).inputDevices();
                if (!context.mounted) return;
                final picked = await showDialog<String>(
                  context: context,
                  builder: (c) => SimpleDialog(
                    title: const Text('Микрофон'),
                    children: [
                      SimpleDialogOption(
                        onPressed: () => Navigator.pop(c, ''),
                        child: const Text('По умолчанию'),
                      ),
                      for (final d in devices)
                        SimpleDialogOption(
                          onPressed: () => Navigator.pop(c, d.id),
                          child: Text(d.label),
                        ),
                      if (devices.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text('Список микрофонов недоступен'),
                        ),
                    ],
                  ),
                );
                if (picked != null) {
                  final name = devices.where((d) => d.id == picked).map((d) => d.label).firstOrNull ?? '';
                  ref.read(captureDeviceProvider.notifier).set(picked, name);
                }
              },
            ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Корзина'),
            subtitle: Text(ref.watch(trashPeriodProvider).label),
            onTap: () async {
              final picked = await showDialog<TrashPeriod>(
                context: context,
                builder: (c) => SimpleDialog(
                  title: const Text('Удалять из корзины'),
                  children: [
                    for (final p in TrashPeriod.values)
                      SimpleDialogOption(
                        onPressed: () => Navigator.pop(c, p),
                        child: Text(p.label),
                      ),
                  ],
                ),
              );
              if (picked != null) ref.read(trashPeriodProvider.notifier).set(picked);
            },
          ),
          const SizedBox(height: 24),
          Text('Синхронизация', style: Theme.of(context).textTheme.titleSmall),
          SwitchListTile(
            title: const Text('Автоматическая синхронизация'),
            value: status.autoSync,
            onChanged: (v) => sync.autoSync = v,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Имя этого устройства'),
            onSubmitted: (_) => _saveName(),
            onEditingComplete: _saveName,
          ),
          const SizedBox(height: 8),
          Text(
            'Порт: ${sync.port} · отпечаток ключа: ${sync.identity.fingerprint}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 24),
          Text('Обновления', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
           SwitchListTile(
             secondary: const Icon(Icons.update),
             title: const Text('Автопроверка обновлений'),
             subtitle: const Text('При открытии приложения, не чаще раза в 6 часов'),
             value: ref.watch(storeProvider).getSetting('updates_auto') != 'false',
             onChanged: (value) {
               ref.read(storeProvider).setSetting('updates_auto', '$value');
               setState(() {});
             },
           ),
           const UpdateCard(),
          const SizedBox(height: 24),
          Text('Файлы', style: Theme.of(context).textTheme.titleSmall),
          SwitchListTile(
            title: const Text('Скачивать файлы автоматически'),
            subtitle: const Text('Выключено: файлы скачиваются кнопкой в заметке'),
            value: sync.autoDownloadFiles,
            onChanged: (v) {
              ref.read(storeProvider).setSetting(SyncService.autoDownloadSetting, v ? 'true' : 'false');
              setState(() {});
            },
          ),
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: const Text('Папка для сохранения файлов'),
            subtitle: Text(
              (ref.watch(storeProvider).getSetting(AttachmentService.saveDirSetting) ?? '').isEmpty
                  ? 'Загрузки (по умолчанию)'
                  : ref.watch(storeProvider).getSetting(AttachmentService.saveDirSetting)!,
            ),
            trailing: TextButton(onPressed: _pickSaveDir, child: const Text('Выбрать')),
          ),
          if ((ref.read(storeProvider).getSetting(AttachmentService.saveDirSetting) ?? '').isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () {
                  ref.read(storeProvider).setSetting(AttachmentService.saveDirSetting, '');
                  setState(() {});
                },
                child: const Text('Вернуть «Загрузки»'),
              ),
            ),
          const SizedBox(height: 24),
          Text('О программе', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Text(
            'NoteVibe — блокнот с синхронизацией напрямую по локальной сети. '
            'Заметки и вложения не уходят в облако и не хранятся на сервере. '
            'Передача шифруется, ключи хранятся в защищённом хранилище ОС.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('Версия $appVersion', style: Theme.of(context).textTheme.bodySmall),
              TextButton.icon(
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                onPressed: () => UpdateService.openUrl('https://github.com/Vagamin/NoteVibe'),
                icon: const Icon(Icons.code, size: 16),
                label: const Text('GitHub'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
