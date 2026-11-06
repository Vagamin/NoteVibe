import 'package:flutter/material.dart';

/// Shared compact typography for preference pages and explanatory cards.
class PreferencesStyle extends StatelessWidget {
  final Widget child;
  const PreferencesStyle({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = theme.textTheme.bodyMedium!.copyWith(fontSize: 14, height: 1.35);
    final secondary = body.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Theme(
      data: theme.copyWith(listTileTheme: theme.listTileTheme.copyWith(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        minVerticalPadding: 8,
        minLeadingWidth: 24,
        horizontalTitleGap: 12,
        titleTextStyle: body.copyWith(fontSize: 16, fontWeight: FontWeight.w600),
        subtitleTextStyle: secondary,
      )),
      child: DefaultTextStyle(style: secondary, child: child),
    );
  }
}
