import 'package:flutter/material.dart';

/// One restrained code surface for the editor and note previews.
BoxDecoration codeDecoration(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  return BoxDecoration(
    color: scheme.surfaceContainerLow,
    border: Border(left: BorderSide(color: scheme.outlineVariant, width: 3)),
    borderRadius: BorderRadius.circular(8),
  );
}
