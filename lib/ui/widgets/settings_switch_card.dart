import 'package:flutter/material.dart';

/// Shared spacing and alignment for settings and device controls.
class SettingsSwitchCard extends StatelessWidget {
  final IconData icon;
  final Widget title;
  final Widget? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  const SettingsSwitchCard({super.key, required this.icon, required this.title,
    this.subtitle, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MergeSemantics(child: Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              SizedBox(width: 24, child: Icon(icon, size: 22, color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(width: 12),
              Expanded(child: DefaultTextStyle(
                style: theme.textTheme.bodyLarge!.copyWith(fontSize: 16, fontWeight: FontWeight.w600, height: 1.3),
                child: title,
              )),
              const SizedBox(width: 8),
              Switch(value: value, onChanged: onChanged),
            ]),
            if (subtitle != null) Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              child: DefaultTextStyle(
                style: theme.textTheme.bodyMedium!.copyWith(fontSize: 14, height: 1.4, color: theme.colorScheme.onSurfaceVariant),
                child: subtitle!,
              ),
            ),
          ]),
        ),
      ),
    ));
  }
}
