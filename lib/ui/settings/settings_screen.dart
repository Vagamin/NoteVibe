import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';

import '../../sync/sync_service.dart';
import '../../update/update_service.dart';
import '../attachments/attachment_service.dart';
import '../providers.dart';
import '../voice/voice_panel.dart';
import 'update_card.dart';
import '../widgets/settings_switch_card.dart';
import '../cache_service.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});
  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late final TextEditingController _name;
  int? _cacheBytes;
  bool _clearingCache = false;

  Future<void> _refreshCache() async {
    try {
      final bytes = await (await temporaryCache()).sizeBytes();
      if (mounted) setState(() => _cacheBytes = bytes);
    } catch (_) { /* The screen still works if temp storage is unavailable. */ }
  }

  Future<void> _clearCache() async {
    setState(() => _clearingCache = true);
    try {
      await (await temporaryCache()).clean(all: true);
      await _refreshCache();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Неиспользуемые временные файлы удалены. Защищённые файлы оставлены.'),
      ));
      }
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Не удалось очистить временные файлы. Попробуйте позже.')));
    } finally {
      if (mounted) setState(() => _clearingCache = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: ref.read(syncProvider).identity.name);
    _refreshCache();
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
      body: Theme(
        data: Theme.of(context).copyWith(
          listTileTheme: Theme.of(context).listTileTheme.copyWith(
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            minVerticalPadding: 8,
            tileColor: Theme.of(context).cardTheme.color,
            minLeadingWidth: 24,
            horizontalTitleGap: 12,
            titleTextStyle: Theme.of(context).textTheme.bodyLarge?.copyWith(fontSize: 16, fontWeight: FontWeight.w600, height: 1.3),
            subtitleTextStyle: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 14, height: 1.4, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
        child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Тема', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          _SettingsTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('Оформление'),
            subtitle: Text(switch (mode) { ThemeMode.system => 'Системная тема', ThemeMode.light => 'Светлая тема', ThemeMode.dark => 'Тёмная тема' }),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: () async {
              final picked = await showDialog<ThemeMode>(context: context, builder: (c) => SimpleDialog(
                title: const Text('Тема приложения'),
                children: [
                  for (final entry in {ThemeMode.system: 'Системная', ThemeMode.light: 'Светлая', ThemeMode.dark: 'Тёмная'}.entries)
                    SimpleDialogOption(onPressed: () => Navigator.pop(c, entry.key), child: Text(entry.value)),
                ],
              ));
              if (picked != null) ref.read(themeModeProvider.notifier).set(picked);
            },
          ),
          const SizedBox(height: 24),
          Text('Список заметок', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          _SettingsTile(
            leading: const Icon(Icons.view_headline_outlined),
            title: const Text('Предпросмотр заметок'),
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
          _SettingsTile(
            leading: const Icon(Icons.graphic_eq),
            title: const Text('Предпросмотр голосовых'),
            subtitle: Text(ref.watch(voicePreviewProvider).label),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: () async {
              final current = ref.read(voicePreviewProvider);
              final picked = await showDialog<VoicePreview>(context: context, builder: (c) => SimpleDialog(
                title: const Text('Записи в карточке заметки'),
                children: [for (final value in VoicePreview.values)
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(c, value),
                    child: Row(children: [Expanded(child: Text(value.label)), if (current == value) const Icon(Icons.check, size: 20)]),
                  ),
                ],
              ));
              if (picked != null) ref.read(voicePreviewProvider.notifier).set(picked);
            },
          ),
          _SettingsTile(
            leading: const Icon(Icons.format_size),
            title: const Text('Размер шрифта заметок'),
            subtitle: Text('${ref.watch(noteFontSizeProvider).label} · Заголовки и текст'),
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
          _SettingsSwitch(
            icon: Icons.drag_indicator,
            title: const Text('Порядок вручную'),
            subtitle: Text(Platform.isWindows ? 'Перетаскивайте заметки мышью.\nВажные заметки остаются сверху.' : 'Удерживайте заметку для выбора.\nУдерживайте повторно для переноса.\nВажные заметки остаются сверху.'),
            value: ref.watch(manualOrderProvider),
            onChanged: (v) => ref.read(manualOrderProvider.notifier).set(v),
          ),
          if (Platform.isWindows)
            _SettingsTile(
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
          _SettingsTile(
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
          const SizedBox(height: 8),
          _SettingsSwitch(
            icon: Icons.sync,
            title: const Text('Автосинхронизация'),
            value: status.autoSync,
            onChanged: (v) => sync.autoSync = v,
          ),
          Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(Icons.devices_outlined, size: 22, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  const SizedBox(width: 14),
                  Text('Имя устройства', style: Theme.of(context).textTheme.bodyLarge?.copyWith(fontSize: 16, fontWeight: FontWeight.w600, height: 1.3)),
                ]),
                const SizedBox(height: 12),
                TextField(
            controller: _name,
            decoration: const InputDecoration(hintText: 'Введите имя', isDense: true),
            onSubmitted: (_) => _saveName(),
            onEditingComplete: _saveName,
          ),
                const SizedBox(height: 12),
                Text('Порт: ${sync.port}\nОтпечаток ключа: ${sync.identity.fingerprint}',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 14, height: 1.4, color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ]),
            ),
          ),
          const SizedBox(height: 24),
          Text('Обновления', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
            _SettingsSwitch(
              icon: Icons.update,
              title: const Text('Проверять обновления'),
              subtitle: const Text('Проверка при открытии приложения.\nНе чаще одного раза в 6 часов.'),
             value: ref.watch(storeProvider).getSetting('updates_auto') != 'false',
             onChanged: (value) {
               ref.read(storeProvider).setSetting('updates_auto', '$value');
               setState(() {});
             },
           ),
           const UpdateCard(),
          const SizedBox(height: 24),
          Text('Файлы', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          _SettingsSwitch(
            icon: Icons.download_outlined,
            title: const Text('Автозагрузка файлов'),
            subtitle: const Text('Загружать вложения с других устройств.\nЕсли выключено — по кнопке в заметке.'),
            value: sync.autoDownloadFiles,
            onChanged: (v) {
              ref.read(storeProvider).setSetting(SyncService.autoDownloadSetting, v ? 'true' : 'false');
              setState(() {});
            },
          ),
          _SettingsTile(
            leading: const Icon(Icons.folder_outlined),
            title: const Text('Папка сохранения'),
            subtitle: Text(
              (ref.watch(storeProvider).getSetting(AttachmentService.saveDirSetting) ?? '').isEmpty
                  ? 'Загрузки (по умолчанию)'
                  : ref.watch(storeProvider).getSetting(AttachmentService.saveDirSetting)!,
            ),
            onTap: _pickSaveDir,
            trailing: const Icon(Icons.chevron_right, size: 20),
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
          Text('Хранилище', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          _SettingsTile(
            leading: const Icon(Icons.cleaning_services_outlined),
            title: const Text('Временные файлы'),
            subtitle: Text('${_cacheBytes == null ? 'Подсчёт…' : '${(_cacheBytes! / 1048576).toStringAsFixed(1)} МБ'}\nАвтоочистка раз в сутки, целевой лимит 50 МБ.\nАктивные файлы и установщики защищены.\nЗаметки и вложения не удаляются.'),
            trailing: IconButton(
              tooltip: 'Очистить временные файлы',
              onPressed: _clearingCache || _cacheBytes == null ? null : _clearCache,
              icon: _clearingCache ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.delete_sweep_outlined),
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
      ),
    );
  }
}

/// Let explanations use the whole row instead of squeezing them between an
/// icon and a switch. Text can still wrap naturally with accessibility scaling.
class _SettingsTile extends StatelessWidget {
  final Widget leading;
  final Widget title;
  final Widget? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  const _SettingsTile({required this.leading, required this.title, this.subtitle, this.trailing, this.onTap});

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.symmetric(vertical: 4),
    child: ListTile(leading: leading, title: title, subtitle: subtitle, trailing: trailing, onTap: onTap),
  );
}

class _SettingsSwitch extends SettingsSwitchCard {
  const _SettingsSwitch({required super.icon, required super.title, super.subtitle,
    required super.value, required super.onChanged});
}
