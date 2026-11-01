import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_version.dart';
import '../providers.dart';

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
          Text('Синхронизация', style: Theme.of(context).textTheme.titleSmall),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
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
          Text(
            'NoteVibe $appVersion\n\n'
            'NoteVibe хранит заметки только на ваших устройствах (SQLite). '
            'Синхронизация идёт напрямую по локальной сети с шифрованием; '
            'ключи сопряжения хранятся в защищённом хранилище ОС.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
