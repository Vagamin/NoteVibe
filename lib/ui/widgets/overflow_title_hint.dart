import 'package:flutter/material.dart';

/// A full-title hint only when the one-line title cannot fit.
class OverflowTitleHint extends StatelessWidget {
  final String title;
  final TextStyle? style;
  final Widget child;
  const OverflowTitleHint({super.key, required this.title, required this.style, required this.child});

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
    final painter = TextPainter(text: TextSpan(text: title, style: style), maxLines: 1,
      textDirection: Directionality.of(context), textScaler: MediaQuery.textScalerOf(context))
      ..layout(maxWidth: constraints.maxWidth);
    final overflow = painter.didExceedMaxLines;
    painter.dispose();
    if (!overflow) return child;
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: title,
      triggerMode: TooltipTriggerMode.longPress,
      waitDuration: const Duration(milliseconds: 500),
      showDuration: const Duration(seconds: 4),
      constraints: BoxConstraints(maxWidth: (MediaQuery.sizeOf(context).width - 32).clamp(0, 420)),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10), border: Border.all(color: scheme.outlineVariant)),
      textStyle: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurface),
      child: child,
    );
  });
}

/// Explicit disclosure avoids competing with editable text selection gestures.
class EditableTitleHint extends StatelessWidget {
  final String title;
  final TextStyle? style;
  final Widget child;
  const EditableTitleHint({super.key, required this.title, required this.style, required this.child});

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
    final painter = TextPainter(text: TextSpan(text: title, style: style), maxLines: 1,
      textDirection: Directionality.of(context), textScaler: MediaQuery.textScalerOf(context))
      ..layout(maxWidth: constraints.maxWidth);
    final overflow = painter.didExceedMaxLines;
    painter.dispose();
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: child),
      if (overflow) IconButton(
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 36, minHeight: 48),
        style: IconButton.styleFrom(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
        tooltip: 'Показать полный заголовок',
        icon: const Icon(Icons.unfold_more, size: 20),
        onPressed: () => showDialog<void>(context: context, builder: (c) => Dialog(
          insetPadding: const EdgeInsets.all(24),
          child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(padding: const EdgeInsets.all(16), child: Column(mainAxisSize: MainAxisSize.min, children: [
              Flexible(child: SingleChildScrollView(child: SelectableText(title,
                style: Theme.of(c).textTheme.titleMedium))),
              const SizedBox(height: 8),
              Align(alignment: Alignment.centerRight, child: TextButton(
                onPressed: () => Navigator.pop(c), child: const Text('Закрыть'))),
            ]))),
        )),
      ),
    ]);
  });
}
