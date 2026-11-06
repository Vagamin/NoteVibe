import 'package:flutter/material.dart';

import '../providers.dart';
import '../../data/vault/vault_biometrics.dart';

class VaultUnlock extends StatefulWidget {
  final List<String> args;
  final void Function(AppServices services) onUnlocked;
  final AppServices? lockedServices;
  final Future<void>? pendingLock;
  const VaultUnlock({super.key, required this.args, required this.onUnlocked, this.lockedServices, this.pendingLock});
  @override
  State<VaultUnlock> createState() => _VaultUnlockState();
}

class _VaultUnlockState extends State<VaultUnlock> {
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;
  bool _biometric = false;
  bool _visible = false;
  @override
  void initState() {
    super.initState();
    VaultBiometrics.enabled().then((value) { if (mounted) setState(() => _biometric = value); }).catchError((Object _) {});
  }
  @override
  void dispose() { _password.dispose(); super.dispose(); }

  Future<void> _unlock({bool biometric = false}) async {
    if (_busy || (!biometric && _password.text.isEmpty)) return;
    setState(() { _busy = true; _error = null; });
    try {
      final password = biometric ? await VaultBiometrics.unlock() : _password.text;
      if (password == null || password.isEmpty) throw StateError('Введите пароль');
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.hidden) {
        throw StateError('Вернитесь в приложение');
      }
      final services = widget.lockedServices ?? await AppServices.init(widget.args, password);
      if (widget.lockedServices != null) {
        await widget.pendingLock;
        await services.vault!.verifyPassword(password);
        await services.sync.start();
      }
      _password.clear();
      if (mounted) widget.onUnlocked(services);
    } catch (_) {
      if (mounted) setState(() { _busy = false; _error = 'Не удалось открыть хранилище. Проверьте пароль. Если пароль верный, возможно повреждение данных.'; });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(body: SafeArea(child: Center(child: SingleChildScrollView(
    padding: const EdgeInsets.all(24), child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 400),
      child: Card(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Icon(Icons.shield_outlined, size: 56, color: Theme.of(context).colorScheme.primary), const SizedBox(height: 20),
        Text('Разблокировать NoteVibe', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 12), const Text('Заметки и синхронизация недоступны до ввода пароля.'),
        const SizedBox(height: 16),
        TextField(controller: _password, autofocus: !_biometric, obscureText: !_visible, enabled: !_busy,
          enableSuggestions: false, autocorrect: false, onSubmitted: (_) => _unlock(),
          decoration: InputDecoration(labelText: 'Пароль', prefixIcon: const Icon(Icons.lock_outline),
            suffixIcon: IconButton(tooltip: _visible ? 'Скрыть пароль' : 'Показать пароль',
              onPressed: () => setState(() => _visible = !_visible), icon: Icon(_visible ? Icons.visibility_off : Icons.visibility)))),
        const SizedBox(height: 16),
        FilledButton(onPressed: _busy ? null : () => _unlock(), child: Text(_busy ? 'Разблокировка…' : 'Разблокировать')),
        if (_biometric) ...[const SizedBox(height: 12), OutlinedButton.icon(
          onPressed: _busy ? null : () => _unlock(biometric: true), icon: const Icon(Icons.fingerprint), label: const Text('Войти по отпечатку'))],
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
      ]))),
    ),
  ))));
}
