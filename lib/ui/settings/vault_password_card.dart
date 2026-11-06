import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers.dart';
import '../../data/vault/vault_session.dart';
import '../../data/vault/vault_transition.dart';
import '../../data/vault/vault_mode.dart';
import '../../main.dart' show restartApplication;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class VaultPasswordCard extends ConsumerStatefulWidget {
  const VaultPasswordCard({super.key});
  @override
  ConsumerState<VaultPasswordCard> createState() => _VaultPasswordCardState();
}

class _VaultPasswordCardState extends ConsumerState<VaultPasswordCard> {
  Future<void> _toggle(bool enabled) async {
    final services = ref.read(servicesProvider);
    await showDialog<void>(context: context, barrierDismissible: false,
      builder: (_) => _ToggleVaultDialog(services: services, enabled: enabled));
  }
  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows) return const SizedBox.shrink();
    final vault = ref.watch(servicesProvider).vault;
    return Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SwitchListTile.adaptive(contentPadding: EdgeInsets.zero, value: vault != null,
        onChanged: ref.watch(servicesProvider).dataDirectory == null ? null : _toggle,
        title: const Text('Шифровать данные'), subtitle: Text(vault == null ? 'Защита базы, вложений и ключей паролем' : 'Зашифрованное хранилище разблокировано'), secondary: const Icon(Icons.lock_outline)),
      Text(vault == null ? 'Сейчас база и вложения не зашифрованы дополнительным паролем приложения.' : 'База и вложения находятся в зашифрованном хранилище.'),
      if (vault != null) TextButton.icon(onPressed: () => showDialog<void>(context: context,
        barrierDismissible: false, builder: (_) => _ChangePasswordDialog(vault: vault)),
        icon: const Icon(Icons.password), label: const Text('Изменить пароль')),
      const SizedBox(height: 8),
      Text('Переключение переносит и проверяет данные, затем перезапускает интерфейс. Экспортированные вами файлы вне приложения не шифруются. Удаление старых файлов не гарантирует их физического стирания с SSD или из системных резервных копий.', style: Theme.of(context).textTheme.bodySmall),
    ])));
  }
}

class _ToggleVaultDialog extends StatefulWidget {
  final AppServices services;
  final bool enabled;
  const _ToggleVaultDialog({required this.services, required this.enabled});
  @override
  State<_ToggleVaultDialog> createState() => _ToggleVaultDialogState();
}

class _ToggleVaultDialogState extends State<_ToggleVaultDialog> {
  final _password = TextEditingController();
  final _repeat = TextEditingController();
  bool _busy = false;
  bool _stopped = false;
  String? _error;
  @override
  void dispose() { _password.dispose(); _repeat.dispose(); super.dispose(); }
  Future<void> _apply() async {
    if (_busy) return;
    if (_password.text.isEmpty || (widget.enabled && _password.text != _repeat.text)) {
      setState(() => _error = 'Введите пароль и совпадающее подтверждение');
      return;
    }
    setState(() { _busy = true; _error = null; });
    final services = widget.services;
    final root = services.dataDirectory!;
    services.transitioning = true;
    try {
      // Validate password BEFORE stopping an unlocked session.
      if (!_stopped && services.vault != null) {
        await services.vault!.verifyPassword(_password.text);
      }
      if (!_stopped) {
        await services.close(releaseLock: false);
        _stopped = true;
      }
      final tmp = await getTemporaryDirectory();
      final caches = [Directory(p.join(tmp.path, 'notevibe_play')), Directory(p.join(tmp.path, 'notevibe_gallery')), Directory(p.join(tmp.path, 'notevibe_clipboard')),
        Directory(p.join(Directory.systemTemp.path, 'notevibe_open'))];
      final deviceId = (await File(p.join(root.path, 'device_id')).readAsString()).trim();
      if (await VaultTransition.pending(root) != null) {
        await VaultTransition.recover(root, deviceId: deviceId, password: _password.text,
          keys: services.legacyKeys!, caches: caches);
      }
      if (widget.enabled && !await VaultMode.encrypted(root)) {
        await VaultTransition.enable(root, deviceId: deviceId, password: _password.text,
          keys: services.legacyKeys!, caches: caches);
      } else if (!widget.enabled && await VaultMode.encrypted(root)) {
        await VaultTransition.disable(root, deviceId: deviceId, password: _password.text,
          keys: services.legacyKeys!, caches: caches);
      }
      await services.applicationLock?.release();
      await restartApplication(services.startupArgs, widget.enabled ? _password.text : null);
    } catch (error) {
      if (!_stopped) services.transitioning = false;
      if (mounted) { setState(() {
        _busy = false;
        _error = 'Перенос не завершён: $error\n${_stopped ? 'Редактирование остановлено. Повторите попытку; при перезапуске перенос будет продолжен по журналу.' : 'Исходные данные не изменены.'}';
      }); }
    }
  }
  @override
  Widget build(BuildContext context) => PopScope(canPop: !_busy && !_stopped, child: AlertDialog(
    title: Text(widget.enabled ? 'Включить шифрование' : 'Отключить шифрование'),
    content: SizedBox(width: 420, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
      Text(widget.enabled ? 'Сохраните пароль: восстановить его невозможно. Не закрывайте приложение во время переноса.' : 'База и вложения станут доступны без пароля приложения. Введите текущий пароль.'),
      const SizedBox(height: 12),
      TextField(controller: _password, obscureText: true, enabled: !_busy,
        enableSuggestions: false, autocorrect: false, decoration: const InputDecoration(labelText: 'Пароль')),
      if (widget.enabled) const SizedBox(height: 16),
      if (widget.enabled) TextField(controller: _repeat, obscureText: true, enabled: !_busy,
        enableSuggestions: false, autocorrect: false, decoration: const InputDecoration(labelText: 'Повторите пароль')),
      if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
    ]))),
    actions: [if (!_stopped) TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Отмена')),
      FilledButton(onPressed: _busy ? null : _apply, child: Text(_busy ? 'Перенос и проверка…' : 'Продолжить'))],
  ));
}

class _ChangePasswordDialog extends StatefulWidget {
  final VaultSession vault;
  const _ChangePasswordDialog({required this.vault});
  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _repeat = TextEditingController();
  bool _busy = false;
  String? _error;
  @override
  void dispose() { _current.dispose(); _next.dispose(); _repeat.dispose(); super.dispose(); }
  Future<void> _save() async {
    if (_busy) return;
    if (_next.text.isEmpty || _next.text != _repeat.text) {
      setState(() => _error = 'Введите новый пароль и совпадающее подтверждение');
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      await widget.vault.changePassword(_current.text, _next.text);
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) setState(() { _busy = false; _error = 'Пароль не изменён. Проверьте текущий пароль и доступность хранилища.'; });
    }
  }
  @override
  Widget build(BuildContext context) => PopScope(canPop: !_busy, child: AlertDialog(
    title: const Text('Изменить пароль'),
    content: SizedBox(width: 360, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
      for (final entry in [(_current, 'Текущий пароль'), (_next, 'Новый пароль'), (_repeat, 'Повторите новый пароль')])
        Padding(padding: const EdgeInsets.only(bottom: 12), child: TextField(controller: entry.$1,
          obscureText: true, enabled: !_busy, enableSuggestions: false, autocorrect: false,
          decoration: InputDecoration(labelText: entry.$2))),
      const Text('Если забудете пароль, восстановить доступ не получится.'),
      if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
    ]))),
    actions: [TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Отмена')),
      FilledButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'Сохранение…' : 'Сохранить'))],
  ));
}
