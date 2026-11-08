import 'package:flutter/material.dart';

/// Clip the item's own ink, not just its label or the outer popup surface.
class RoundedPopupMenuItem<T> extends PopupMenuItem<T> {
  const RoundedPopupMenuItem({super.key, super.value, super.onTap,
    super.enabled, super.height, super.padding, required super.child});

  @override
  PopupMenuItemState<T, RoundedPopupMenuItem<T>> createState() => _RoundedPopupMenuItemState<T>();
}

class _RoundedPopupMenuItemState<T> extends PopupMenuItemState<T, RoundedPopupMenuItem<T>> {
  @override
  Widget build(BuildContext context) => Material(
    type: MaterialType.transparency,
    borderRadius: BorderRadius.circular(12),
    clipBehavior: Clip.antiAlias,
    child: super.build(context),
  );
}
