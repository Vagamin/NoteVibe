import 'package:flutter/material.dart';

import '../providers.dart';

class VaultUnlock extends StatefulWidget {
  final List<String> args;
  final void Function(AppServices services) onUnlocked;
  const VaultUnlock({super.key, required this.args, required this.onUnlocked});
  @override
  State<VaultUnlock> createState() => _VaultUnlockState();
}

class _VaultUnlockState extends State<VaultUnlock> {
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;
  @override
  void dispose() { _password.dispose(); super.dispose(); }

  Future<void> _unlock() async {
    if (_busy || _password.text.isEmpty) return;
    setState(() { _busy = true; _error = null; });
    try {
      final services = await AppServices.init(widget.args, _password.text);
      _password.clear();
      if (mounted) widget.onUnlocked(services);
    } catch (_) {
      if (mounted) setState(() { _busy = false; _error = 'Не удалось открыть хранилище. Проверьте пароль. Если пароль верный, возможно повреждение данных.'; });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(body: SafeArea(child: Center(child: SingleChildScrollView(
    padding: const EdgeInsets.all(24), child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 400),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Icon(Icons.lock_outline, size: 48), const SizedBox(height: 16),
        Text('Разблокировать NoteVibe', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 12), const Text('Заметки и синхронизация недоступны до ввода пароля.'),
        const SizedBox(height: 16),
        TextField(controller: _password, autofocus: true, obscureText: true, enabled: !_busy,
          enableSuggestions: false, autocorrect: false, onSubmitted: (_) => _unlock(),
          decoration: const InputDecoration(labelText: 'Пароль')),
        const SizedBox(height: 16),
        FilledButton(onPressed: _busy ? null : _unlock, child: Text(_busy ? 'Разблокировка…' : 'Открыть')),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
      ]),
    ),
  ))));
}
