import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';

/// A persistent warning, not a disappearing Snackbar: RAM-only edits must not
/// look safely saved when disk persistence fails.
class VaultSaveStatus extends ConsumerStatefulWidget {
  const VaultSaveStatus({super.key});
  @override
  ConsumerState<VaultSaveStatus> createState() => _VaultSaveStatusState();
}

class _VaultSaveStatusState extends ConsumerState<VaultSaveStatus> {
  bool _retrying = false;
  @override
  Widget build(BuildContext context) {
    final vault = ref.watch(servicesProvider).vault;
    if (vault == null) return const SizedBox.shrink();
    final notes = vault.notes;
    return StreamBuilder<void>(stream: notes.persistenceChanges, builder: (context, _) {
      if (notes.lastSaveError == null) return const SizedBox.shrink();
      final scheme = Theme.of(context).colorScheme;
      return SafeArea(bottom: false, child: Material(color: scheme.errorContainer, child: Padding(
        padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Изменения ещё не сохранены на диск. Не закрывайте приложение. Проверьте свободное место и доступ к папке хранилища.',
            style: TextStyle(color: scheme.onErrorContainer)),
          Align(alignment: Alignment.centerRight, child: TextButton(
            onPressed: _retrying ? null : () async {
              setState(() => _retrying = true);
              try { await notes.flush(); } catch (_) { /* Persistent warning remains. */ }
              finally { if (mounted) setState(() => _retrying = false); }
            }, child: Text(_retrying ? 'Сохранение…' : 'Повторить сохранение'))),
        ]),
      )));
    });
  }
}
