import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers.dart';
import '../../data/vault/vault_session.dart';
import '../../data/vault/vault_transition.dart';
import '../../data/vault/vault_mode.dart';
import '../../data/vault/vault_biometrics.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import '../../main.dart' show restartApplication;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class VaultPasswordCard extends ConsumerStatefulWidget {
  const VaultPasswordCard({super.key});
  @override
  ConsumerState<VaultPasswordCard> createState() => _VaultPasswordCardState();
}

class _VaultPasswordCardState extends ConsumerState<VaultPasswordCard> {
  Future<String?> _passwordPrompt(String title) async {
    final controller = TextEditingController();
    final password = await showDialog<String>(context: context, builder: (c) => AlertDialog(
      title: Text(title), content: TextField(controller: controller, obscureText: true,
        autofocus: true, enableSuggestions: false, autocorrect: false,
        decoration: const InputDecoration(labelText: 'Текущий пароль'),
        onSubmitted: (value) => Navigator.pop(c, value)),
      actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Отмена')),
        FilledButton(onPressed: () => Navigator.pop(c, controller.text), child: const Text('Подтвердить'))],
    ));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    controller.dispose();
    return password;
  }

  Future<void> _backup() async {
    final services = ref.read(servicesProvider);
    final password = await _passwordPrompt('Экспорт базы без шифрования');
    if (password == null || !mounted) return;
    try {
      await services.vault!.verifyPassword(password);
      await services.flush();
      final bytes = services.vault!.notes.database.exportBytes();
      try {
        final path = await FilePicker.saveFile(fileName: 'NoteVibe-backup-${DateTime.now().millisecondsSinceEpoch}.db',
          bytes: bytes, mimeType: 'application/octet-stream', dialogTitle: 'Сохранить расшифрованную базу');
        if (path != null && mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('База сохранена без шифрования. Вложения хранятся отдельно и в этот файл не входят.')));
      } finally { bytes.fillRange(0, bytes.length, 0); }
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Экспорт не выполнен. Проверьте пароль и доступ к файлу.')));
    }
  }

  Future<void> _biometrics() async {
    try {
      if (await VaultBiometrics.enabled()) {
        await VaultBiometrics.disable();
      } else {
        final password = await _passwordPrompt('Подключить отпечаток');
        if (password == null || !mounted) return;
        await ref.read(servicesProvider).vault!.verifyPassword(password);
        await VaultBiometrics.enroll(password);
      }
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Настройка входа по отпечатку изменена')));
    } on PlatformException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message ?? 'Биометрия недоступна')));
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Не удалось подтвердить пароль')));
    }
  }
  Future<void> _toggle(bool enabled) async {
    final services = ref.read(servicesProvider);
    await showDialog<void>(context: context, barrierDismissible: false,
      builder: (_) => _ToggleVaultDialog(services: services, enabled: enabled));
  }
  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows && !Platform.isAndroid) return const SizedBox.shrink();
    final vault = ref.watch(servicesProvider).vault;
    return Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SwitchListTile.adaptive(contentPadding: EdgeInsets.zero, value: vault != null,
        onChanged: ref.watch(servicesProvider).dataDirectory == null ? null : _toggle,
        title: const Text('Шифровать данные'), subtitle: Text(vault == null ? 'Защита базы, вложений и ключей паролем' : 'Зашифрованное хранилище разблокировано'), secondary: const Icon(Icons.lock_outline)),
      Text(vault == null ? 'Сейчас база и вложения не зашифрованы дополнительным паролем приложения.' : 'База и вложения находятся в зашифрованном хранилище.'),
      if (vault != null) TextButton.icon(onPressed: () => showDialog<void>(context: context,
        barrierDismissible: false, builder: (_) => _ChangePasswordDialog(vault: vault)),
        icon: const Icon(Icons.password), label: const Text('Изменить пароль')),
      if (vault != null && Platform.isAndroid) TextButton.icon(onPressed: _biometrics,
        icon: const Icon(Icons.fingerprint), label: const Text('Настроить вход по отпечатку')),
      if (vault != null) TextButton.icon(onPressed: _backup,
        icon: const Icon(Icons.backup_outlined), label: const Text('Экспорт расшифрованной базы')),
      if (vault != null) const Padding(padding: EdgeInsets.only(top: 4),
        child: Text('Копия базы не защищена паролем. Файлы вложений в неё не входят.')),
      const SizedBox(height: 8),
      const Text('При переключении данные переносятся и проверяются, затем интерфейс перезапускается.'),
      const SizedBox(height: 8),
      const Text('Внешние экспорты не шифруются. Удаление исходных файлов не гарантирует их физического стирания с накопителя или из системных резервных копий.'),
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
      if (Platform.isAndroid && widget.enabled) {
        // Remove plaintext plugin caches before committing the transition.
        await FilePicker.clearTemporaryFiles();
        await const MethodChannel('notevibe/update').invokeMethod<void>('vaultSecureScreen', {'enabled': true});
      }
      if (await VaultTransition.pending(root) != null) {
        await VaultTransition.recover(root, deviceId: deviceId, password: _password.text,
          keys: services.legacyKeys!, caches: caches);
      }
      if (widget.enabled && !await VaultMode.encrypted(root)) {
        await VaultTransition.enable(root, deviceId: deviceId, password: _password.text,
          keys: services.legacyKeys!, caches: caches);
      } else if (!widget.enabled && await VaultMode.encrypted(root)) {
        await VaultBiometrics.disable();
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
      await VaultBiometrics.disable();
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
