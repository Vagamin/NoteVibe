import 'package:flutter/material.dart';

/// Selection marker used everywhere in the app: a filled circle when chosen,
/// an empty circle otherwise.
class SelectDot extends StatelessWidget {
  final bool checked;

  const SelectDot({super.key, required this.checked});

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Icon(
      checked ? Icons.check_circle : Icons.radio_button_unchecked,
      size: 20,
      color: checked ? s.primary : s.outline,
    );
  }
}
