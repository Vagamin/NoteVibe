import 'package:flutter/material.dart';

/// Persistent, theme-aware announcement. Only an explicit action dismisses it.
class UpdateBanner extends StatelessWidget {
  final String version;
  final VoidCallback onOpen;
  final VoidCallback onLater;
  const UpdateBanner({super.key, required this.version, required this.onOpen, required this.onLater});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(liveRegion: true, container: true, child: Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      color: scheme.primaryContainer,
      elevation: 3,
      shadowColor: scheme.primary.withValues(alpha: 0.25),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: scheme.primary.withValues(alpha: 0.5))),
      child: Padding(padding: const EdgeInsets.all(16), child: LayoutBuilder(builder: (context, constraints) {
        final heading = Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(
            color: scheme.primary, borderRadius: BorderRadius.circular(14)),
            child: Icon(Icons.system_update_rounded, color: scheme.onPrimary, size: 28)),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Доступно обновление', style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: scheme.onPrimaryContainer, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text('NoteVibe $version · Посмотрите, что нового',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onPrimaryContainer)),
          ])),
        ]);
        final actions = Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.end, children: [
          TextButton(onPressed: onLater, style: TextButton.styleFrom(foregroundColor: scheme.onPrimaryContainer),
            child: const Text('Позже')),
          FilledButton.icon(onPressed: onOpen, icon: const Icon(Icons.arrow_forward_rounded, size: 20),
            label: const Text('Посмотреть обновление')),
        ]);
        if (constraints.maxWidth >= 760 && MediaQuery.textScalerOf(context).scale(1) <= 1.3) {
          return Row(children: [Expanded(child: heading), const SizedBox(width: 24), actions]);
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          heading, const SizedBox(height: 16), actions,
        ]);
      })),
    ));
  }
}
